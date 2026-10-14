import AppKit
import ServiceManagement
import SweepCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Busy {
        case idle
        case scanning
        case cleaning
    }

    @Published var free: Int64 = 0
    @Published var total: Int64 = 0
    @Published var state = SweepState()
    @Published var config = Config()
    @Published var configError: String?
    @Published var summary: ScanSummary?
    @Published var blocked: [String] = []
    @Published var pins: [Pin] = []
    @Published var pinsError = false
    @Published var busy = Busy.idle
    @Published var confirming = false
    @Published var message: String?
    @Published var launchAtLogin = false
    /// 整块硬盘的占用。测量要几分钟，跟在扫描后面在后台做，结果缓存。
    @Published var storage: StorageReport?
    @Published var measuringStorage = false
    /// 面板内容的高度，外壳据此调整窗口大小。
    @Published var panelHeight: CGFloat = 0

    private var timer: Timer?

    /// live 为 false 时不注册登录项、不启动定时器（用于离屏渲染界面截图）。
    init(live: Bool = true) {
        summary = ScanSummary.load(from: Env.live().scanFile)
        storage = StorageReport.load(from: Env.live().storageFile)
        refresh()
        guard live else { return }
        enableLaunchAtLoginOnFirstRun()
        scanIfStale()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var menuTitle: String { total > 0 ? "\(free / Int64(Format.gigabyte))G" : "Sweep" }

    /// 读取磁盘、状态、配置和标记名单。都是小文件，面板每次打开时调用。
    func refresh() {
        let env = Env.live()
        let disk = Disk.usage(at: env.home)
        free = disk.free
        total = disk.total
        state = SweepState.load(from: env.stateFile)
        do {
            config = try Config.load(from: env.configFile)
            configError = nil
        } catch {
            configError = "配置文件无法读取，清理已暂停。"
        }
        do {
            pins = try PinStore(file: env.pinsFile).all()
            pinsError = false
        } catch {
            pinsError = true
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 扫描与清理

    func scan(then completion: (() -> Void)? = nil) {
        guard busy == .idle, configError == nil else { return }
        busy = .scanning
        message = nil
        let config = config
        Task.detached(priority: .utility) {
            let env = Env.live()
            // 关着的规则也量出来，只用于展示；真正清理时 Runner 会按开关重新扫描
            let candidates = Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile), includeDisabled: true).scan()
            let summary = ScanSummary.make(from: candidates, date: env.now)
            try? summary.save(to: env.scanFile)
            try? ReportText.scan(candidates, limitPerRule: nil, disabled: config.disabledRules)
                .write(to: env.previewFile, atomically: true, encoding: .utf8)
            let blocked = candidates.filter(\.blockedByProcess).map {
                "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.url.lastPathComponent) 已有 \(Format.bytes($0.bytes))，相关进程停掉后会清理"
            }
            await MainActor.run {
                self.summary = summary
                self.blocked = blocked
                self.busy = .idle
                completion?()
                self.measureStorage(with: candidates)
            }
        }
    }

    /// 占用超过 6 小时没测过（或用户要求刷新）时，在后台重新测量整块硬盘。
    func measureStorage(with candidates: [Candidate], force: Bool = false) {
        guard !measuringStorage else { return }
        if !force, let storage, Date().timeIntervalSince(storage.date) < 6 * 3600 { return }
        measuringStorage = true
        Task.detached(priority: .utility) {
            let env = Env.live()
            let report = VolumeUsage.current().map { StorageReport.build(env: env, candidates: candidates, volumes: $0) }
            if let report { try? report.save(to: env.storageFile) }
            await MainActor.run {
                if let report { self.storage = report }
                self.measuringStorage = false
            }
        }
    }

    /// 「刷新」按钮：重新扫描并重新测量占用。
    func refreshStorage() {
        guard busy == .idle else { return }
        storage = storage.map { var s = $0; s.date = .distantPast; return s }
        scan()
    }

    /// 点「立即清理」：先保证有一份新的扫描结果，再让用户确认。
    func requestClean() {
        if let summary, Date().timeIntervalSince(summary.date) < 600 {
            confirming = true
        } else {
            scan { self.confirming = true }
        }
    }

    func confirmClean() {
        guard busy == .idle else { return }
        confirming = false
        busy = .cleaning
        Task.detached(priority: .utility) {
            let env = Env.live()
            let text: String
            do {
                // 删除前会重新扫描一遍，只删此刻仍然符合条件的项
                let outcome = try Runner(env: env).run(mode: .manual)
                let report = outcome.report
                let failed = (report?.errors.isEmpty ?? true) ? "" : "，\(report?.errors.count ?? 0) 项失败（见日志）"
                text = "已清理 \(report?.deleted.count ?? 0) 项，回收 \(Format.bytes(report?.freedBytes ?? 0))\(failed)。"
                // 用户亲手确认过一次，此后定时任务才真正执行删除
                var state = SweepState.load(from: env.stateFile)
                if !state.armed {
                    state.armed = true
                    try? state.save(to: env.stateFile)
                }
            } catch {
                text = "清理失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self.busy = .idle
                self.refresh()
                self.scan { self.message = text }
                self.message = text
            }
        }
    }

    // MARK: - 设置

    func saveConfig() {
        do {
            try config.save(to: Env.live().configFile)
        } catch {
            message = "保存设置失败：\(error.localizedDescription)"
        }
    }

    func isEnabled(_ rule: RuleID) -> Bool { config.isEnabled(rule) }

    /// 开着的规则合计能清多少。关着的规则虽然也量了，但不计入。
    var cleanable: (count: Int, bytes: Int64) {
        summary?.deletable(in: Set(RuleID.allCases).subtracting(config.disabledRules)) ?? (0, 0)
    }

    /// 上次扫描太久了就重新扫一遍。启动时和每次打开面板时调用，保证看到的不是过时的数字。
    func scanIfStale(maxAge: TimeInterval = 600) {
        guard busy == .idle else { return }
        if let summary, Date().timeIntervalSince(summary.date) < maxAge { return }
        scan()
    }

    func setEnabled(_ rule: RuleID, _ on: Bool) {
        switch rule {
        case .buildCaches: config.buildCaches.enabled = on
        case .dependencies: config.dependencies.enabled = on
        case .workCopies: config.workCopies.enabled = on
        case .agentTemp: config.agentTemp.enabled = on
        case .conversations: config.conversations.enabled = on
        case .claudeConversations: config.claudeConversations.enabled = on
        case .packageCaches: config.packageCaches.enabled = on
        case .appCaches: config.appCaches.enabled = on
        case .artifacts: config.artifacts.enabled = on
        case .recordings: config.recordings.enabled = on
        case .bigItems: return
        }
        saveConfig()
    }

    func setArmed(_ on: Bool) {
        let env = Env.live()
        var current = SweepState.load(from: env.stateFile)
        current.armed = on
        try? current.save(to: env.stateFile)
        state = current
    }

    func unpin(_ pin: Pin) {
        _ = try? PinStore(file: Env.live().pinsFile).remove(matching: pin.token)
        refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            message = "设置开机启动失败：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func enableLaunchAtLoginOnFirstRun() {
        let key = "didConfigureLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }

    // MARK: - 打开文件

    func openPreview() {
        let url = Env.live().previewFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            scan { NSWorkspace.shared.open(url) }
        }
    }

    func openLog() {
        let url = Env.live().logFile
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            message = "还没有清理记录。"
        }
    }
}
