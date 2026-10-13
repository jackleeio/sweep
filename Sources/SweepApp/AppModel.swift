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

    private var timer: Timer?

    /// live 为 false 时不注册登录项、不启动定时器（用于离屏渲染界面截图）。
    init(live: Bool = true) {
        summary = ScanSummary.load(from: Env.live().scanFile)
        refresh()
        guard live else { return }
        enableLaunchAtLoginOnFirstRun()
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
            let candidates = Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan()
            let summary = ScanSummary.make(from: candidates, date: env.now)
            try? summary.save(to: env.scanFile)
            try? ReportText.scan(candidates, limitPerRule: nil).write(to: env.previewFile, atomically: true, encoding: .utf8)
            let blocked = candidates.filter(\.blockedByProcess).map {
                "\($0.url.deletingLastPathComponent().lastPathComponent)/\($0.url.lastPathComponent) 已有 \(Format.bytes($0.bytes))，相关进程停掉后会清理"
            }
            await MainActor.run {
                self.summary = summary
                self.blocked = blocked
                self.busy = .idle
                completion?()
            }
        }
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

    func isEnabled(_ rule: RuleID) -> Bool {
        switch rule {
        case .buildCaches: return config.buildCaches.enabled
        case .agentTemp: return config.agentTemp.enabled
        case .conversations: return config.conversations.enabled
        case .packageCaches: return config.packageCaches.enabled
        case .appCaches: return config.appCaches.enabled
        case .dependencies: return config.dependencies.enabled
        case .artifacts: return config.artifacts.enabled
        case .workCopies: return true
        }
    }

    func setEnabled(_ rule: RuleID, _ on: Bool) {
        switch rule {
        case .buildCaches: config.buildCaches.enabled = on
        case .agentTemp: config.agentTemp.enabled = on
        case .conversations: config.conversations.enabled = on
        case .packageCaches: config.packageCaches.enabled = on
        case .appCaches: config.appCaches.enabled = on
        case .dependencies: config.dependencies.enabled = on
        case .artifacts: config.artifacts.enabled = on
        case .workCopies: return
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
