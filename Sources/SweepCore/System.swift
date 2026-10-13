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
        var env = Env(home: home, now: Date(), processProbe: LiveProcessProbe(), freeBytes: { Disk.usage(at: home).free })
        env.externalReferences = { ExternalReferences.collect(home: home) }
        return env
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

public struct ScanItem: Codable, Equatable {
    public var path: String
    public var bytes: Int64
    public var reason: String
}

public struct KeptGroup: Codable, Equatable {
    public var reason: String
    public var count: Int
    public var bytes: Int64
}

public struct RuleSummary: Codable, Equatable {
    public var deletableCount: Int
    public var deletableBytes: Int64
    public var keptCount: Int
    public var keptBytes: Int64
    /// 可清理项里最大的几个，界面展开时显示。
    public var top: [ScanItem] = []
    /// 保留的项按原因分组。
    public var kept: [KeptGroup] = []

    public init(deletableCount: Int = 0, deletableBytes: Int64 = 0, keptCount: Int = 0, keptBytes: Int64 = 0) {
        self.deletableCount = deletableCount
        self.deletableBytes = deletableBytes
        self.keptCount = keptCount
        self.keptBytes = keptBytes
    }

    /// 旧版本存的摘要没有明细字段，缺失时按空处理。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deletableCount = try c.decode(Int.self, forKey: .deletableCount)
        deletableBytes = try c.decode(Int64.self, forKey: .deletableBytes)
        keptCount = try c.decode(Int.self, forKey: .keptCount)
        keptBytes = try c.decode(Int64.self, forKey: .keptBytes)
        top = try c.decodeIfPresent([ScanItem].self, forKey: .top) ?? []
        kept = try c.decodeIfPresent([KeptGroup].self, forKey: .kept) ?? []
    }
}

/// 一次扫描的汇总，界面用它立即显示上次结果。
public struct ScanSummary: Codable, Equatable {
    public var date: Date
    var rules: [String: RuleSummary]

    public subscript(rule: RuleID) -> RuleSummary? { rules[rule.rawValue] }
    public var deletableBytes: Int64 { rules.values.reduce(0) { $0 + $1.deletableBytes } }
    public var deletableCount: Int { rules.values.reduce(0) { $0 + $1.deletableCount } }

    private static let topCount = 8

    public static func make(from candidates: [Candidate], date: Date) -> ScanSummary {
        var rules: [String: RuleSummary] = [:]
        for (rule, items) in Dictionary(grouping: candidates, by: \.rule) {
            let deletable = items.filter(\.isDelete).sorted { $0.bytes > $1.bytes }
            let kept = items.filter { !$0.isDelete }
            var entry = RuleSummary(deletableCount: deletable.count, deletableBytes: deletable.reduce(0) { $0 + $1.bytes },
                                    keptCount: kept.count, keptBytes: kept.reduce(0) { $0 + $1.bytes })
            entry.top = deletable.prefix(topCount).map { ScanItem(path: $0.url.path, bytes: $0.bytes, reason: $0.reason) }
            entry.kept = Dictionary(grouping: kept, by: \.reason)
                .map { KeptGroup(reason: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.bytes }) }
                .sorted { ($0.bytes, $1.reason) > ($1.bytes, $0.reason) }
            rules[rule.rawValue] = entry
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

extension RuleID {
    /// 一两句话说明这条规则管什么、什么时候清。阈值取自当前设置。
    public func detail(_ config: Config) -> String {
        let idle = "\(Format.number(config.idleDays)) 天"
        switch self {
        case .buildCaches:
            return "项目里的 .next、bun 编译残留和 Tauri 的 target。\(idle)没更新，或单个超过 \(Format.number(config.buildCaches.sizeCapGB)) GB 时清理，下次构建会重新生成。"
        case .dependencies:
            return "闲置项目的 node_modules 和能重建的虚拟环境。项目 \(Format.number(config.dependencies.idleDays)) 天没有改动时清理，回到项目后重新安装即可。"
        case .agentTemp:
            return "Agent 构建时建的临时目录（~/.cache/bnbot-* 等）。\(idle)没更新时清理。"
        case .conversations:
            return "Codex 和 Claude 的会话记录。\(idle)没更新且没有标记时删除，删除后无法恢复。"
        case .packageCaches:
            return "Yarn、npm、pnpm、bun、uv、pip 的下载缓存和 Docker Scout。合计超过 \(Format.number(config.packageCaches.totalCapGB)) GB 时清空，之后按需重新下载。"
        case .appCaches:
            let kept = config.appCaches.keepAITools ? "系统缓存、浏览器测试内核和 AI 工具的缓存不动" : "系统缓存和浏览器测试内核不动"
            return "~/Library/Caches 里其他应用的缓存。\(idle)没更新时清理；\(kept)。"
        case .artifacts:
            return "Codex 生成的图片和视频。\(Format.number(config.artifacts.idleDays)) 天没更新时删除，删除后无法恢复。"
        case .workCopies:
            return "worktree 和构建副本，里面可能有未提交的代码，所以只显示体积，不自动清理。"
        }
    }
}

/// 找出项目目录之外、指向项目内部的引用。被引用的项目即使很久没改动，依赖也在被使用。
public enum ExternalReferences {
    /// 这些目录里的符号链接解析后的真实路径。`@scope` 目录再往下看一层（npm 的 scoped 包）。
    public static func linkTargets(in directories: [URL]) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func visit(_ dir: URL, scoped: Bool) {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let url = dir.appendingPathComponent(name)
                switch FileKind.of(url) {
                case .symlink:
                    if let real = realPath(url) { out.append(real) }
                case .directory where !scoped && name.hasPrefix("@"):
                    visit(url, scoped: true)
                default:
                    continue
                }
            }
        }
        for dir in directories { visit(dir, scoped: false) }
        return out
    }

    /// 定时任务配置里出现的所有绝对路径，包括写在 shell 命令字符串中间的。
    public static func launchAgentPaths(in directory: URL) -> [String] {
        var out: [String] = []
        func collect(_ value: Any) {
            if let text = value as? String {
                for token in text.split(whereSeparator: { " \t\n\"';&|=<>()".contains($0) }) {
                    if token.hasPrefix("/") {
                        out.append(String(token))
                    } else if token.hasPrefix("~/") {
                        out.append(NSString(string: String(token)).expandingTildeInPath)
                    }
                }
            } else if let list = value as? [Any] {
                list.forEach(collect)
            } else if let dict = value as? [String: Any] {
                dict.values.forEach(collect)
            }
        }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".plist") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
            collect(plist)
        }
        return out
    }

    public static func collect(home: URL) -> [String] {
        let fm = FileManager.default
        func children(_ rel: String) -> [URL] {
            let dir = home.appendingPathComponent(rel)
            return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).map { dir.appendingPathComponent($0) }
        }
        // 全局安装的包、PATH 上的命令、各 agent 的技能目录
        var dirs = ["/opt/homebrew/lib/node_modules", "/usr/local/lib/node_modules", "/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(fileURLWithPath: $0) }
        dirs += [".bun/install/global/node_modules", ".bun/bin", ".local/bin", "Library/pnpm", ".yarn/bin", ".config/yarn/link",
                 ".claude/skills", ".codex/skills", ".bnbot/skills"].map(home.appendingPathComponent)
        dirs += children("Library/pnpm/global").map { $0.appendingPathComponent("node_modules") }
        dirs += children(".nvm/versions/node").flatMap { [$0.appendingPathComponent("lib/node_modules"), $0.appendingPathComponent("bin")] }
        return linkTargets(in: dirs) + launchAgentPaths(in: home.appendingPathComponent("Library/LaunchAgents"))
    }
}
