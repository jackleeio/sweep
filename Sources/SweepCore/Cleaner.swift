import Foundation

public struct DeletedItem: Codable, Equatable {
    public var rule: RuleID
    public var path: String
    public var bytes: Int64
    public var reason: String
}

public struct RunReport: Equatable {
    public var date: Date
    /// 为 true 时 deleted 是「将会删除」的清单，实际什么都没删。
    public var dryRun: Bool
    public var deleted: [DeletedItem] = []
    public var errors: [String] = []

    public var freedBytes: Int64 { deleted.reduce(0) { $0 + $1.bytes } }
}

/// 执行删除。只处理 verdict 为 delete 的项，且每一项删除前都重新过一遍 PathGuard。
public struct Cleaner {
    let env: Env

    /// 这些规则删完后会顺手清掉因此变空的上级目录（如 Codex 的日期目录）。
    private static let prunedRules: Set<RuleID> = [.conversations, .artifacts]
    private static let maxLogBytes: Int64 = 5 << 20

    public init(env: Env) { self.env = env }

    /// progress 在每一项处理完（且日志已落盘）后调用。
    /// 日志逐项写而不是攒到最后：清理可能中途被终止，已经删掉的必须留有记录。
    public func run(_ candidates: [Candidate], dryRun: Bool, progress: ((DeletedItem) -> Void)? = nil) -> RunReport {
        var report = RunReport(date: env.now, dryRun: dryRun)
        let fm = FileManager.default

        for candidate in candidates {
            guard case .delete(let reason) = candidate.verdict else { continue }
            let targets = [candidate.url] + candidate.extraURLs

            // 主路径和附属路径全部通过校验才动手，避免只删一半
            let rejected = targets.lazy.compactMap { url in
                PathGuard.validate(url, root: candidate.root, minDepth: candidate.minDepth).map { (url, $0) }
            }.first
            if let (url, rejection) = rejected {
                report.errors.append("\(url.path)：校验未通过（\(rejection)）")
                appendLog(logLine("REFUSE", candidate, "\(rejection)"))
                continue
            }

            if !dryRun {
                var failure: String?
                for url in targets {
                    do {
                        try fm.removeItem(at: url)
                    } catch {
                        failure = "\(url.path)：\(error.localizedDescription)"
                        break
                    }
                }
                if let failure {
                    report.errors.append(failure)
                    appendLog(logLine("ERROR", candidate, failure))
                    continue
                }
                if Self.prunedRules.contains(candidate.rule) {
                    pruneEmptyParents(of: candidate.url, upTo: candidate.root)
                }
            }

            let item = DeletedItem(rule: candidate.rule, path: candidate.url.path, bytes: candidate.bytes, reason: reason)
            report.deleted.append(item)
            appendLog(logLine(dryRun ? "DRYRUN" : "DELETE", candidate, reason))
            progress?(item)
        }
        return report
    }

    /// 自下而上移除空目录，到 root 为止（不含 root）。rmdir 只对空目录成功。
    private func pruneEmptyParents(of url: URL, upTo root: URL) {
        let rootPath = root.standardizedFileURL.path
        var dir = url.deletingLastPathComponent().standardizedFileURL
        while dir.path.hasPrefix(rootPath + "/") {
            guard rmdir(dir.path) == 0 else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    private func logLine(_ action: String, _ candidate: Candidate, _ detail: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        let stamp = formatter.string(from: env.now)
        return "\(stamp) \(action) \(candidate.rule.rawValue) \(Format.bytes(candidate.bytes)) \(candidate.url.path) — \(detail)"
    }

    private func appendLog(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: env.logDir, withIntermediateDirectories: true)

        // 日志自己也不能无限增长：超过上限就轮转一份
        if let size = (try? fm.attributesOfItem(atPath: env.logFile.path))?[.size] as? Int64, size > Self.maxLogBytes {
            let old = env.logFile.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: env.logFile, to: old)
        }

        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: env.logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: env.logFile)
        }
    }
}

public struct RunRecord: Codable, Equatable {
    public var date: Date
    /// manual / daily / emergency
    public var kind: String
    public var deletedCount: Int
    public var freedBytes: Int64
    public var errorCount: Int
}

public struct SweepState: Codable, Equatable {
    /// 用户确认过首次清理后才为 true；为 false 时定时任务只扫描不删除。
    public var armed = false
    public var lastRun: Date?
    public var lastFreedBytes: Int64 = 0
    public var lastDeletedCount = 0
    public var lastErrorCount = 0
    public var totalFreedBytes: Int64 = 0
    /// 上次每日例行运行的时间（未确认时指上次提醒确认的时间）。
    public var lastDailyRun: Date?
    /// 上次按收紧规则清理的时间。
    public var lastTightRun: Date?
    /// 上次提醒「清理后空间仍然不足」的时间。
    public var lastLowSpaceNotice: Date?
    /// 最近若干次清理的记录，新的在后。
    public var history: [RunRecord] = []

    private static let historyLimit = 20

    public init() {}

    /// 字段缺失时取默认值，这样加新字段不会让旧的状态文件读不出来（那会把 armed 重置掉）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        armed = try c.decodeIfPresent(Bool.self, forKey: .armed) ?? false
        lastRun = try c.decodeIfPresent(Date.self, forKey: .lastRun)
        lastFreedBytes = try c.decodeIfPresent(Int64.self, forKey: .lastFreedBytes) ?? 0
        lastDeletedCount = try c.decodeIfPresent(Int.self, forKey: .lastDeletedCount) ?? 0
        lastErrorCount = try c.decodeIfPresent(Int.self, forKey: .lastErrorCount) ?? 0
        totalFreedBytes = try c.decodeIfPresent(Int64.self, forKey: .totalFreedBytes) ?? 0
        lastDailyRun = try c.decodeIfPresent(Date.self, forKey: .lastDailyRun)
        lastTightRun = try c.decodeIfPresent(Date.self, forKey: .lastTightRun)
        lastLowSpaceNotice = try c.decodeIfPresent(Date.self, forKey: .lastLowSpaceNotice)
        history = try c.decodeIfPresent([RunRecord].self, forKey: .history) ?? []
    }

    mutating func append(_ record: RunRecord) {
        history.append(record)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
    }

    /// 读不出来就当作全新状态。这是安全方向：armed 回到 false，需要重新确认。
    public static func load(from url: URL) -> SweepState {
        (try? JSONFiles.read(SweepState.self, from: url)) ?? SweepState()
    }

    public func save(to url: URL) throws {
        try JSONFiles.write(self, to: url)
    }
}

public enum RunMode {
    /// launchd 定时触发。未确认过首次清理时只扫描。
    case scheduled
    /// 用户主动触发，直接执行。
    case manual
}

public struct RunOutcome {
    /// 实际执行（或 dry-run）的结果；定时任务因未确认而跳过时为 nil。
    public var report: RunReport?
    public var pendingBytes: Int64 = 0
    public var pendingCount = 0
    /// 本该清理、但因为有进程在用而保留的缓存。
    public var blocked: [Candidate] = []
}

public enum TickAction: Equatable {
    /// 没到时间，空间也够，什么都没做。
    case none
    /// 还没确认过首次清理，只扫描并提醒。
    case pendingConfirmation
    /// 每日例行清理。
    case daily
    /// 可用空间低于警戒线，立即清理。
    case emergency
}

public struct TickOutcome {
    public var action = TickAction.none
    public var reports: [RunReport] = []
    public var blocked: [Candidate] = []
    public var pendingBytes: Int64 = 0
    public var pendingCount = 0
    /// 清理后可用空间仍低于警戒线，且今天还没提醒过。
    public var stillLow = false
    public var freeAfter: Int64 = 0
}

public struct Runner {
    let env: Env

    /// 定时运行和手动清理都不碰工作副本（它只用于展示）。
    private static let cleanedRules = Set(RuleID.allCases).subtracting([.workCopies])
    /// 两次收紧清理之间至少间隔这么久，避免空间持续不足时反复扫描。
    private static let tightInterval: TimeInterval = 3600
    private static let noticeInterval: TimeInterval = 24 * 3600

    public init(env: Env) { self.env = env }

    private func scanner(_ config: Config, tight: Bool) -> Scanner {
        Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile), tight: tight)
    }

    /// 定时任务的入口，每隔几分钟被调用一次，自行判断该不该干活：
    /// - 可用空间低于警戒线：立即按收紧规则清理（每小时最多一次）；
    /// - 今天的例行清理还没做：按常规规则清理，之后若仍低于目标余量，再按收紧规则清一遍；
    /// - 用户还没确认过首次清理：只扫描并提醒，每天一次，绝不删除。
    public func tick() throws -> TickOutcome {
        // 配置损坏时在这里抛错，什么都不删
        let config = try Config.load(from: env.configFile)
        var state = SweepState.load(from: env.stateFile)
        var outcome = TickOutcome()

        func since(_ date: Date?) -> TimeInterval { date.map { env.now.timeIntervalSince($0) } ?? .infinity }
        let floor = Int64(config.lowSpaceGB * Format.gigabyte)
        let target = Int64(config.targetFreeGB * Format.gigabyte)
        let dailyDue = state.lastDailyRun.map { $0 < lastDailyBoundary(hour: config.dailyHour) } ?? true
        outcome.freeAfter = env.freeBytes()

        guard state.armed else {
            guard dailyDue else { return outcome }
            let deletable = scanner(config, tight: false).scan(rules: Self.cleanedRules).filter(\.isDelete)
            outcome.action = .pendingConfirmation
            outcome.pendingBytes = deletable.reduce(0) { $0 + $1.bytes }
            outcome.pendingCount = deletable.count
            state.lastDailyRun = env.now.wholeSeconds
            try state.save(to: env.stateFile)
            return outcome
        }

        var passes: [Bool]
        if outcome.freeAfter < floor, since(state.lastTightRun) >= Self.tightInterval {
            outcome.action = .emergency
            passes = [true]
        } else if dailyDue {
            outcome.action = .daily
            passes = [false]
        } else {
            return outcome
        }

        var index = 0
        while index < passes.count {
            let tight = passes[index]
            let candidates = scanner(config, tight: tight).scan(rules: Self.cleanedRules)
            outcome.reports.append(Cleaner(env: env).run(candidates, dryRun: false))
            outcome.blocked = candidates.filter(\.blockedByProcess)
            if tight {
                state.lastTightRun = env.now.wholeSeconds
            } else {
                state.lastDailyRun = env.now.wholeSeconds
                // 常规清理后仍达不到目标余量，就按收紧规则再清一遍
                if env.freeBytes() < target, since(state.lastTightRun) >= Self.tightInterval { passes.append(true) }
            }
            index += 1
        }

        record(outcome.reports, kind: outcome.action == .emergency ? "emergency" : "daily", in: &state)
        outcome.freeAfter = env.freeBytes()
        if outcome.freeAfter < floor, since(state.lastLowSpaceNotice) >= Self.noticeInterval {
            outcome.stillLow = true
            state.lastLowSpaceNotice = env.now.wholeSeconds
        }
        try state.save(to: env.stateFile)
        return outcome
    }

    /// 最近一次已经过去的「每日清理时刻」。上次例行清理早于它，就说明今天的还没做。
    private func lastDailyBoundary(hour: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.date(bySettingHour: min(max(hour, 0), 23), minute: 0, second: 0, of: env.now) ?? env.now
        return today <= env.now ? today : calendar.date(byAdding: .day, value: -1, to: today) ?? today
    }

    private func record(_ reports: [RunReport], kind: String, in state: inout SweepState) {
        let freed = reports.reduce(Int64(0)) { $0 + $1.freedBytes }
        state.lastRun = env.now.wholeSeconds
        state.lastFreedBytes = freed
        state.lastDeletedCount = reports.reduce(0) { $0 + $1.deleted.count }
        state.lastErrorCount = reports.reduce(0) { $0 + $1.errors.count }
        state.totalFreedBytes += freed
        state.append(RunRecord(date: env.now.wholeSeconds, kind: kind, deletedCount: state.lastDeletedCount,
                               freedBytes: freed, errorCount: state.lastErrorCount))
    }

    /// 单次清理。mode 为 scheduled 且用户尚未确认时只扫描；tick() 是定时任务实际使用的入口。
    public func run(mode: RunMode, dryRun: Bool = false, tight: Bool = false) throws -> RunOutcome {
        let config = try Config.load(from: env.configFile)
        var state = SweepState.load(from: env.stateFile)
        let candidates = scanner(config, tight: tight).scan(rules: Self.cleanedRules)

        var outcome = RunOutcome()
        outcome.blocked = candidates.filter(\.blockedByProcess)

        if mode == .scheduled, !state.armed {
            let deletable = candidates.filter(\.isDelete)
            outcome.pendingBytes = deletable.reduce(0) { $0 + $1.bytes }
            outcome.pendingCount = deletable.count
            return outcome
        }

        let report = Cleaner(env: env).run(candidates, dryRun: dryRun)
        outcome.report = report

        if !dryRun {
            record([report], kind: mode == .manual ? "manual" : "daily", in: &state)
            try state.save(to: env.stateFile)
        }
        return outcome
    }
}
