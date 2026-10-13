import Foundation

/// 通过进程列表和各进程的工作目录，判断项目的构建缓存是否正在被使用。
/// 一个实例只取一次进程快照，每次运行应新建实例。
public final class LiveProcessProbe: ProcessProbe {
    private lazy var snapshot: [(pid: pid_t, command: String)]? = Self.processList()
    private var directories: [pid_t: String?] = [:]

    public init() {}

    private static func needles(for kind: CacheKind) -> [String] {
        switch kind {
        case .next: return ["next dev", "next build", "next start", "next-server", "turbopack"]
        case .cargoTarget: return ["cargo", "rustc", "tauri"]
        case .bunBuild: return ["bun build"]
        case .dependencies: return ["node", "bun", "npm", "pnpm", "yarn", "deno", "vite", "tsx", "python", "uvicorn", "gunicorn", "celery"]
        }
    }

    /// 命令属于会读写该类缓存的工具，且工作目录在项目内。
    /// 只看工作目录会误伤：停在项目里的终端、编辑器、MCP 服务都不该算。
    static func matches(command: String, cwd: String, projectDir: String, kind: CacheKind) -> Bool {
        guard needles(for: kind).contains(where: command.contains) else { return false }
        // 文件系统不区分大小写，同一目录可能以不同大小写出现
        let project = projectDir.lowercased()
        let dir = cwd.lowercased()
        return dir == project || dir.hasPrefix(project + "/")
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// 取不到时返回 nil，调用方应按「在用」处理。
    static func processList() -> [(pid: pid_t, command: String)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axww", "-o", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let trimmed = line.drop { $0 == " " }
            guard let space = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<space]) else { return nil }
            return (pid, String(trimmed[trimmed.index(after: space)...]))
        }
    }

    public func isInUse(projectDir: URL, kind: CacheKind) -> Bool {
        guard let snapshot else { return true }
        let project = realPath(projectDir) ?? projectDir.path
        let needles = Self.needles(for: kind)
        for entry in snapshot where needles.contains(where: entry.command.contains) {
            if directories[entry.pid] == nil { directories[entry.pid] = .some(Self.workingDirectory(of: entry.pid)) }
            guard let cwd = directories[entry.pid] ?? nil else { continue }
            if Self.matches(command: entry.command, cwd: cwd, projectDir: project, kind: kind) { return true }
        }
        return false
    }
}

extension Env {
    /// 真实环境。设置 SWEEP_HOME 可以把所有路径指向另一个目录，用于演练。
    public static func live() -> Env {
        let override = ProcessInfo.processInfo.environment["SWEEP_HOME"].map { URL(fileURLWithPath: $0) }
        let home = override ?? FileManager.default.homeDirectoryForCurrentUser
        return Env(home: home, now: Date(), processProbe: LiveProcessProbe(), freeBytes: { Disk.usage(at: home).free })
    }
}

public enum Disk {
    /// free 与「系统设置 › 储存空间」口径一致（含可清除空间）。
    public static func usage(at url: URL) -> (free: Int64, total: Int64) {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return (0, 0) }
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return (free, Int64(values.volumeTotalCapacity ?? 0))
    }
}

extension RuleID {
    public var title: String {
        switch self {
        case .buildCaches: return "构建缓存"
        case .dependencies: return "闲置项目的依赖"
        case .agentTemp: return "Agent 临时目录"
        case .conversations: return "Agent 对话"
        case .packageCaches: return "包与工具缓存"
        case .appCaches: return "应用缓存"
        case .artifacts: return "Agent 产物"
        case .workCopies: return "工作副本"
        }
    }
}

public enum ReportText {
    /// 把扫描结果排成可读的清单。limitPerRule 为 nil 时不截断。
    public static func scan(_ candidates: [Candidate], limitPerRule: Int? = 15) -> String {
        var lines: [String] = []
        for rule in RuleID.allCases {
            let items = candidates.filter { $0.rule == rule }
            guard !items.isEmpty else { continue }

            let deletable = items.filter(\.isDelete).sorted { $0.bytes > $1.bytes }
            lines.append("\(rule.title) — 可清理 \(deletable.count) 项，\(Format.bytes(total(deletable)))")
            let shown = limitPerRule.map { Array(deletable.prefix($0)) } ?? deletable
            for item in shown { lines.append(row(item)) }
            if shown.count < deletable.count {
                lines.append("  … 另有 \(deletable.count - shown.count) 项，\(Format.bytes(total(Array(deletable.dropFirst(shown.count)))))")
            }

            // 被保护的项逐条列出原因；普通的「最近在用」只给汇总
            let kept = items.filter { !$0.isDelete }
            let notable = kept.filter { $0.blockedByProcess || $0.reason.hasPrefix("已标记") }
            for item in notable { lines.append("  保留" + row(item).dropFirst(1)) }
            let ordinary = kept.filter { !($0.blockedByProcess || $0.reason.hasPrefix("已标记")) }
            for (reason, group) in Dictionary(grouping: ordinary, by: \.reason).sorted(by: { $0.key < $1.key }) {
                lines.append("  保留 \(group.count) 项，\(Format.bytes(total(group)))（\(reason)）")
            }
            lines.append("")
        }
        let all = candidates.filter(\.isDelete)
        lines.append("合计可清理 \(all.count) 项，\(Format.bytes(total(all)))")
        return lines.joined(separator: "\n")
    }

    private static func total(_ items: [Candidate]) -> Int64 { items.reduce(0) { $0 + $1.bytes } }

    private static func row(_ item: Candidate) -> String {
        let size = Format.bytes(item.bytes)
        return "  \(String(repeating: " ", count: max(0, 9 - size.count)))\(size)  \(item.url.path)（\(item.reason)）"
    }
}

public enum Notifier {
    /// 发一条系统通知。设置 SWEEP_NO_NOTIFY 可关闭（演练时用）。
    public static func post(title: String, body: String) {
        guard ProcessInfo.processInfo.environment["SWEEP_NO_NOTIFY"] == nil else { return }
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

public struct RuleSummary: Codable, Equatable {
    public var deletableCount: Int
    public var deletableBytes: Int64
    public var keptCount: Int
    public var keptBytes: Int64
}

/// 一次扫描的汇总，界面用它立即显示上次结果。
public struct ScanSummary: Codable, Equatable {
    public var date: Date
    var rules: [String: RuleSummary]

    public subscript(rule: RuleID) -> RuleSummary? { rules[rule.rawValue] }
    public var deletableBytes: Int64 { rules.values.reduce(0) { $0 + $1.deletableBytes } }
    public var deletableCount: Int { rules.values.reduce(0) { $0 + $1.deletableCount } }

    public static func make(from candidates: [Candidate], date: Date) -> ScanSummary {
        var rules: [String: RuleSummary] = [:]
        for candidate in candidates {
            var entry = rules[candidate.rule.rawValue] ?? RuleSummary(deletableCount: 0, deletableBytes: 0, keptCount: 0, keptBytes: 0)
            if candidate.isDelete {
                entry.deletableCount += 1
                entry.deletableBytes += candidate.bytes
            } else {
                entry.keptCount += 1
                entry.keptBytes += candidate.bytes
            }
            rules[candidate.rule.rawValue] = entry
        }
        return ScanSummary(date: date, rules: rules)
    }

    public static func load(from url: URL) -> ScanSummary? {
        (try? JSONFiles.read(ScanSummary.self, from: url)) ?? nil
    }

    public func save(to url: URL) throws {
        try JSONFiles.write(self, to: url)
    }
}

extension Env {
    public var scanFile: URL { supportDir.appendingPathComponent("last-scan.json") }
    public var previewFile: URL { supportDir.appendingPathComponent("preview.txt") }
}
