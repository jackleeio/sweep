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

    public func run(_ candidates: [Candidate], dryRun: Bool) -> RunReport {
        var report = RunReport(date: env.now, dryRun: dryRun)
        var lines: [String] = []
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
                lines.append(logLine("REFUSE", candidate, "\(rejection)"))
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
                    lines.append(logLine("ERROR", candidate, failure))
                    continue
                }
                if Self.prunedRules.contains(candidate.rule) {
                    pruneEmptyParents(of: candidate.url, upTo: candidate.root)
                }
            }

            report.deleted.append(DeletedItem(rule: candidate.rule, path: candidate.url.path,
                                              bytes: candidate.bytes, reason: reason))
            lines.append(logLine(dryRun ? "DRYRUN" : "DELETE", candidate, reason))
        }

        appendLog(lines)
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
        let stamp = ISO8601DateFormatter().string(from: env.now)
        return "\(stamp) \(action) \(candidate.rule.rawValue) \(Format.bytes(candidate.bytes)) \(candidate.url.path) — \(detail)"
    }

    private func appendLog(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: env.logDir, withIntermediateDirectories: true)

        // 日志自己也不能无限增长：超过上限就轮转一份
        if let size = (try? fm.attributesOfItem(atPath: env.logFile.path))?[.size] as? Int64, size > Self.maxLogBytes {
            let old = env.logFile.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: env.logFile, to: old)
        }

        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: env.logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: env.logFile)
        }
    }
}

public struct State: Codable, Equatable {
    /// 用户确认过首次清理后才为 true；为 false 时定时任务只扫描不删除。
    public var armed = false
    public var lastRun: Date?
    public var lastFreedBytes: Int64 = 0
    public var lastDeletedCount = 0
    public var lastErrorCount = 0
    public var totalFreedBytes: Int64 = 0

    public init() {}

    /// 读不出来就当作全新状态。这是安全方向：armed 回到 false，需要重新确认。
    public static func load(from url: URL) -> State {
        (try? JSONFiles.read(State.self, from: url)) ?? State()
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

public struct Runner {
    let env: Env

    public init(env: Env) { self.env = env }

    public func run(mode: RunMode, dryRun: Bool = false) throws -> RunOutcome {
        // 配置损坏时在这里抛错，什么都不删
        let config = try Config.load(from: env.configFile)
        var state = State.load(from: env.stateFile)

        let rules = Set(RuleID.allCases).subtracting([.workCopies])
        let candidates = Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan(rules: rules)

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
            state.lastRun = env.now.wholeSeconds
            state.lastFreedBytes = report.freedBytes
            state.lastDeletedCount = report.deleted.count
            state.lastErrorCount = report.errors.count
            state.totalFreedBytes += report.freedBytes
            try state.save(to: env.stateFile)
        }
        return outcome
    }
}
