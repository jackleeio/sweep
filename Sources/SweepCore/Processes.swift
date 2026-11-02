import Foundation

/// 结束闲置进程的几条规则。和删文件的 RuleID 分开：对象是进程树，不是路径。
public enum ProcessRule: String, Codable, CaseIterable {
    /// 父 agent 已退出、被 launchd 收养的残留进程
    case orphans
    /// Codex 应用每个对话各起一套的 MCP 和工具进程
    case codexTools
    /// agent 启动后不再用的 dev server、构建和测试
    case devServers
    /// 开着不用的 agent 终端会话
    case idleSessions

    public var title: String {
        switch self {
        case .orphans: return "孤儿残留进程"
        case .codexTools: return "Codex 积压的工具进程"
        case .devServers: return "agent 遗留的 dev server 和构建"
        case .idleSessions: return "闲置的 agent 终端会话"
        }
    }
}

public struct ProcessEntry: Equatable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var executable: String
    /// 读不到时为空（别的用户的进程）。
    public var arguments: [String]
    /// 启动时间（微秒）。和 pid 一起认定是不是同一个进程，防止 pid 被复用后结束错。
    public var startMicros: Int64
    /// 累计用掉的 CPU 时间。
    public var cpuSeconds: Double
    /// 实际占用的内存（含被压缩和换出的部分），与「活动监视器」的「内存」一列口径一致。
    public var memory: Int64
    /// 控制终端，如 ttys005。
    public var tty: String?
    /// 工作目录。用来认出同一个项目的多个 dev server；读不到为 nil。
    public var cwd: String?

    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, executable: String, arguments: [String],
                startMicros: Int64, cpuSeconds: Double, memory: Int64, tty: String?, cwd: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.uid = uid
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.startMicros = startMicros
        self.cpuSeconds = cpuSeconds
        self.memory = memory
        self.tty = tty
        self.cwd = cwd
    }

    public var command: String { arguments.isEmpty ? executable : arguments.joined(separator: " ") }
    public var key: String { "\(pid)@\(startMicros)" }
}

public struct ProcessSnapshot {
    public var processes: [ProcessEntry]
    public var userID: UInt32
    public var selfPID: Int32
    /// launchd 托管的进程。读不到时为 nil，此时分不清孤儿和常驻服务，孤儿规则一个都不结束。
    public var launchdPIDs: Set<Int32>?
    public var underMemoryPressure: Bool
    /// 各终端最后一次有输入的时间。
    public var ttyInput: [String: Date]

    public init(processes: [ProcessEntry], userID: UInt32, selfPID: Int32, launchdPIDs: Set<Int32>?,
                underMemoryPressure: Bool, ttyInput: [String: Date]) {
        self.processes = processes
        self.userID = userID
        self.selfPID = selfPID
        self.launchdPIDs = launchdPIDs
        self.underMemoryPressure = underMemoryPressure
        self.ttyInput = ttyInput
    }
}

public protocol ProcessSystem {
    /// 读不到进程表时返回 nil，这一轮什么都不结束。
    func snapshot() -> ProcessSnapshot?
    /// 先 SIGTERM，宽限几秒后对还在的发 SIGKILL。pid 和启动时间都对得上才动手。返回确实已经结束的。
    func end(_ processes: [ProcessEntry]) -> [ProcessEntry]
}

public struct NoProcessSystem: ProcessSystem {
    public init() {}
    public func snapshot() -> ProcessSnapshot? { nil }
    public func end(_ processes: [ProcessEntry]) -> [ProcessEntry] { [] }
}

/// 从命令行认出进程是什么。只认得出的才会被结束，认不出的一律不碰。
enum ProcessSignature {
    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let mcp = regex(#"(^|[^a-z0-9])mcp([^a-z0-9]|$)|@modelcontextprotocol/"#)
    private static let devTool = regex([
        #"(^|[\s/])(next (dev|build)|next-server|vite|webpack|turbopack|jest|vitest|tsc|nodemon|storybook|workerd)([\s:]|$)"#,
        #"(^|[\s/])(bun test|esbuild --service|wrangler dev)"#,
        #"(^|[\s/])(npm|pnpm|yarn|bun) (run )?(dev|build|test|start)([\s:]|$)"#,
    ].joined(separator: "|"))
    /// 常驻的 dev server，以及一次性的构建和测试。内存上限和「同一项目多份」只针对前者：
    /// 构建本来就吃内存、跑完自己退出，中途结束只会让 agent 重来。
    private static let server = regex([
        #"(^|[\s/])(next dev|next-server|vite|nodemon|storybook|wrangler dev)([\s:]|$)"#,
        #"(^|[\s/])(npm|pnpm|yarn|bun) (run )?(dev|start)([\s:]|$)"#,
    ].joined(separator: "|"))
    private static let buildOrTest = regex([
        #"(^|[\s/])(next build|vite build|tsc|jest|vitest|playwright|bun test)([\s:]|$)"#,
        #"(^|[\s/])(npm|pnpm|yarn|bun) (run )?(build|test)([\s:]|$)"#,
    ].joined(separator: "|"))
    /// 只是用来套一层的进程：本身不说明什么，看它下面跑的是什么。
    private static let wrappers: Set<String> = ["sh", "bash", "zsh", "dash", "timeout", "gtimeout", "env", "nohup"]
    private static let agentNames: Set<String> = ["claude", "codex", "gemini", "opencode", "cursor-agent", "aider",
                                                  "goose", "amp", "droid", "kimi", "qwen", "crush"]

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func isMCP(_ command: String) -> Bool { matches(mcp, command) }
    static func isDevTool(_ command: String) -> Bool { matches(devTool, command) }
    /// 树里跑着 dev server，并且没有在构建或测试。
    static func isServerTree(_ members: [ProcessEntry]) -> Bool {
        members.contains { matches(server, $0.command) } && !members.contains { matches(buildOrTest, $0.command) }
    }
    static func isWrapper(_ p: ProcessEntry) -> Bool { wrappers.contains(p.name) }

    /// 临时目录只认 /tmp 和 /var/folders/…/T/。/var/folders 下的其他目录放着应用的缓存和包装过的应用。
    private static let temp = regex(#"(^|\s)(/private)?/tmp/|/var/folders/[^/]+/[^/]+/T/"#)
    static func isTemp(_ command: String) -> Bool { matches(temp, command) }

    /// 应用、扩展、XPC 服务里的程序。它们的父进程本来就是 launchd，永远不算孤儿。
    static func isBundled(_ p: ProcessEntry) -> Bool {
        [".app/", ".appex/", ".xpc/", ".framework/"].contains { p.executable.contains($0) }
    }

    /// Claude Code 会话的临时目录：/tmp/claude-<uid>/<项目>/<会话 id>/…
    private static let claudeScratch = regex(#"/claude-[0-9]+/([^/\s]+)/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/"#)
    static func claudeSessions(in command: String) -> [(project: String, session: String)] {
        claudeScratch.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap { match in
            guard let project = Range(match.range(at: 1), in: command), let session = Range(match.range(at: 2), in: command)
            else { return nil }
            return (String(command[project]), String(command[session]))
        }
    }

    static func isAgent(_ p: ProcessEntry) -> Bool {
        let name = p.name.lowercased()
        if agentNames.contains(name) || name.hasPrefix("grok") { return true }
        // Claude Code 的可执行文件以版本号命名
        if p.executable.contains("/.local/share/claude/versions/") { return true }
        // node 或 bun 跑起来的 CLI，看脚本名
        if name == "node" || name == "bun", p.arguments.count > 1 {
            return agentNames.contains(URL(fileURLWithPath: p.arguments[1]).lastPathComponent.lowercased())
        }
        return false
    }

    /// Codex 应用（ChatGPT 或 Codex 桌面版）内置的 codex。终端里的 codex 是会话，不算。
    static func isCodexApp(_ p: ProcessEntry) -> Bool {
        p.name == "codex" && p.tty == nil && p.executable.contains(".app/Contents/")
    }

    static func isCodexTool(_ command: String) -> Bool { isMCP(command) || command.contains("/cua_node/") }
}

/// 每次运行记下各进程累计用掉的 CPU，靠前后对比判断它闲置了多久。
public struct ProcessWatch: Codable, Equatable {
    public struct Seen: Codable, Equatable {
        public var cpu: Double
        /// 最近一次有像样的 CPU 活动（或所在终端有输入）的时间。
        public var lastActive: Date
        /// 最近一次明显在忙（或所在终端有输入）的时间。终端界面空转也要用一点 CPU，会话按这个算。
        public var lastBusy: Date
    }

    public var date: Date?
    public var seen: [String: Seen] = [:]

    /// 两次观察之间用掉的 CPU 达到这个比例才算活动 / 在忙。
    static let activeShare = 0.01
    static let busyShare = 0.05
    /// 换算比例时最多按这么长的间隔算。睡眠后醒来间隔很长，按实际间隔会把真实的活动摊薄。
    static let window: TimeInterval = 600

    public init() {}

    public mutating func observe(_ snapshot: ProcessSnapshot, now: Date) {
        let window = date.map { min(max(now.timeIntervalSince($0), 1), Self.window) } ?? Self.window
        var next: [String: Seen] = [:]
        for p in snapshot.processes where p.uid == snapshot.userID {
            // 第一次看到：不知道它之前在干什么，按「刚刚还在用」算
            guard var entry = seen[p.key] else {
                next[p.key] = Seen(cpu: p.cpuSeconds, lastActive: now, lastBusy: now)
                continue
            }
            let used = p.cpuSeconds - entry.cpu
            let typed = date.flatMap { last in p.tty.flatMap { snapshot.ttyInput[$0] }.map { $0 > last } } ?? false
            entry.cpu = p.cpuSeconds
            if typed || used >= Self.activeShare * window { entry.lastActive = now }
            if typed || used >= Self.busyShare * window { entry.lastBusy = now }
            next[p.key] = entry
        }
        seen = next
        date = now
    }

    /// 读不出来就从头观察。这是安全方向：所有进程都当作刚刚还在用。
    public static func load(from url: URL) -> ProcessWatch {
        (try? JSONFiles.read(ProcessWatch.self, from: url)) ?? ProcessWatch()
    }

    public func save(to url: URL) throws {
        try JSONFiles.write(self, to: url)
    }
}

public enum ProcessVerdict: Equatable {
    case end(reason: String)
    case keep(reason: String)
}

public struct ProcessCandidate: Equatable {
    public let rule: ProcessRule
    /// 整棵进程树，根在前。结束时一起结束。
    public let members: [ProcessEntry]
    public let idleSince: Date
    public let verdict: ProcessVerdict

    public var root: ProcessEntry { members[0] }
    public var memory: Int64 { members.reduce(0) { $0 + $1.memory } }

    public var isEnd: Bool {
        if case .end = verdict { return true }
        return false
    }

    public var reason: String {
        switch verdict {
        case .end(let r), .keep(let r): return r
        }
    }
}

/// 按规则从进程表里挑出候选，并判断结束还是保留。不碰真实进程。
public struct ProcessPlanner {
    let config: Config.Processes
    let now: Date
    /// Claude 会话的记录文件最后更新的时间（参数是项目目录名和会话 id）；没有记录返回 nil。
    let claudeActivity: (String, String) -> Date?

    /// Claude Code 会把后台任务放到父进程之外运行，父进程是 launchd 不代表会话已经结束。
    /// 会话在这么久之内还有动静，它留下的进程就保留。
    static let claudeSessionGrace: TimeInterval = 6 * 3600

    public init(config: Config.Processes, now: Date, claudeActivity: @escaping (String, String) -> Date? = { _, _ in nil }) {
        self.config = config
        self.now = now
        self.claudeActivity = claudeActivity
    }

    public func plan(_ snapshot: ProcessSnapshot, watch: ProcessWatch) -> [ProcessCandidate] {
        let byPID = Dictionary(snapshot.processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Int32: [ProcessEntry]] = [:]
        for p in snapshot.processes where p.pid > 1 { children[p.ppid, default: []].append(p) }

        func tree(_ root: ProcessEntry) -> [ProcessEntry] {
            var out: [ProcessEntry] = []
            var visited: Set<Int32> = []
            func visit(_ p: ProcessEntry) {
                guard visited.insert(p.pid).inserted else { return }
                out.append(p)
                for child in (children[p.pid] ?? []).sorted(by: { $0.pid < $1.pid }) { visit(child) }
            }
            visit(root)
            return out
        }

        func ancestors(_ p: ProcessEntry) -> [ProcessEntry] {
            var out: [ProcessEntry] = []
            var current = p
            while current.ppid > 1, let parent = byPID[current.ppid], out.count < 64 {
                out.append(parent)
                current = parent
            }
            return out
        }

        // Sweep 自己和它的上级（比如运行 sweep 的 agent 会话）无论如何不结束
        var protected: Set<Int32> = [snapshot.selfPID]
        if let me = byPID[snapshot.selfPID] { protected.formUnion(ancestors(me).map(\.pid)) }

        var found: [(rule: ProcessRule, root: ProcessEntry)] = []
        func add(_ rule: ProcessRule, _ p: ProcessEntry) {
            if !found.contains(where: { $0.root.pid == p.pid }) { found.append((rule, p)) }
        }

        if config.orphans {
            for p in snapshot.processes where p.ppid == 1 && p.uid == snapshot.userID && !ProcessSignature.isBundled(p) {
                if snapshot.launchdPIDs?.contains(p.pid) == true { continue }
                let command = p.command
                if p.tty != nil {
                    // 有终端的多半是手动起的；只有 MCP 不会有人手动起
                    if ProcessSignature.isMCP(command) { add(.orphans, p) }
                    continue
                }
                let leftover = { (c: String) in
                    ProcessSignature.isMCP(c) || ProcessSignature.isDevTool(c) || ProcessSignature.isTemp(c)
                }
                if leftover(command) || (ProcessSignature.isWrapper(p) && tree(p).dropFirst().contains { leftover($0.command) }) {
                    add(.orphans, p)
                }
            }
        }

        if config.codexTools {
            for host in snapshot.processes where ProcessSignature.isCodexApp(host) {
                for tool in children[host.pid] ?? [] where ProcessSignature.isCodexTool(tool.command) { add(.codexTools, tool) }
            }
        }

        if config.devServers {
            for p in snapshot.processes where ProcessSignature.isDevTool(p.command) {
                // 只取最上层的一个：npm run dev → next dev → next-server 算一棵
                if let parent = byPID[p.ppid], ProcessSignature.isDevTool(parent.command) { continue }
                if ancestors(p).contains(where: ProcessSignature.isAgent) { add(.devServers, p) }
            }
        }

        if config.idleSessions {
            for p in snapshot.processes where p.tty != nil && ProcessSignature.isAgent(p) && !ProcessSignature.isCodexApp(p) {
                add(.idleSessions, p)
            }
        }

        // 同一个项目目录里有几个 agent 起的 dev server：最近在用的那个算正主（一样就留先起的），其余是多余的
        var duplicateOf: [Int32: Int32] = [:]
        let devServers = found.filter { $0.rule == .devServers && ProcessSignature.isServerTree(tree($0.root)) }
            .map { ($0.root, lastActivity(tree($0.root), .devServers, watch)) }
        let byProject = Dictionary(grouping: devServers.filter { !($0.0.cwd ?? "").isEmpty }, by: { $0.0.cwd! })
        for group in byProject.values where group.count > 1 {
            let kept = group.max { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.startMicros > b.0.startMicros }!
            for (root, _) in group where root.pid != kept.0.pid { duplicateOf[root.pid] = kept.0.pid }
        }

        let judged = found.map {
            judge($0.rule, tree($0.root), snapshot: snapshot, watch: watch, protected: protected, duplicateOf: duplicateOf[$0.root.pid])
        }
        // 外层整棵要结束时，里面单独列出的候选就不必再列
        let ending = Set(judged.filter(\.isEnd).map(\.root.pid))
        return judged.filter { candidate in !ancestors(candidate.root).contains { ending.contains($0.pid) } }
    }

    /// 整棵树里最近一次有活动的时间。没见过的进程按「刚刚还在用」算。
    private func lastActivity(_ members: [ProcessEntry], _ rule: ProcessRule, _ watch: ProcessWatch) -> Date {
        members.map { p -> Date in
            guard let seen = watch.seen[p.key] else { return now }
            return rule == .idleSessions ? seen.lastBusy : seen.lastActive
        }.max() ?? now
    }

    private func judge(_ rule: ProcessRule, _ members: [ProcessEntry], snapshot: ProcessSnapshot, watch: ProcessWatch,
                       protected: Set<Int32>, duplicateOf: Int32?) -> ProcessCandidate {
        let idleSince = lastActivity(members, rule, watch)
        let idleHours = max(0, now.timeIntervalSince(idleSince)) / 3600
        // 孤儿里的 dev server 可能还开着页面在看，和 agent 名下的 dev server 等一样久
        let orphanDevServer = rule == .orphans && members.contains { ProcessSignature.isDevTool($0.command) }
        var threshold = orphanDevServer ? max(config.orphanIdleHours, config.devServerIdleHours) : config.idleHours(rule)
        var idleText = "闲置 \(String(format: "%.1f", idleHours)) 小时"
        if let duplicateOf {
            threshold = config.duplicateDevServerIdleMinutes / 60
            idleText += "，同一项目还有 pid \(duplicateOf) 在用"
        }
        func make(_ verdict: ProcessVerdict) -> ProcessCandidate {
            ProcessCandidate(rule: rule, members: members, idleSince: idleSince, verdict: verdict)
        }

        if members.contains(where: { protected.contains($0.pid) }) { return make(.keep(reason: "包含 Sweep 自己或它的上级进程")) }
        if members.contains(where: { $0.uid != snapshot.userID }) { return make(.keep(reason: "进程树里有别的用户的进程")) }
        if let hit = config.excludes.first(where: { ex in !ex.isEmpty && members.contains { $0.command.contains(ex) } }) {
            return make(.keep(reason: "在排除名单里（\(hit)）"))
        }
        if rule == .orphans, snapshot.launchdPIDs == nil {
            return make(.keep(reason: "读不到 launchd 的服务列表，分不清是不是常驻服务"))
        }
        if rule == .orphans {
            let sessions = members.flatMap { ProcessSignature.claudeSessions(in: $0.command) }
            let latest = sessions.compactMap { claudeActivity($0.project, $0.session) }.max()
            if let latest, now.timeIntervalSince(latest) < Self.claudeSessionGrace {
                let ago = String(format: "%.1f", max(0, now.timeIntervalSince(latest)) / 3600)
                return make(.keep(reason: "所属的 Claude 会话 \(ago) 小时前还有动静"))
            }
        }
        let memory = members.reduce(Int64(0)) { $0 + $1.memory }
        if rule == .devServers, config.devServerMemoryCapGB > 0, Double(memory) > config.devServerMemoryCapGB * Format.gigabyte,
           ProcessSignature.isServerTree(members) {
            return make(.end(reason: "内存 \(Format.bytes(memory)) 超过上限 \(Format.number(config.devServerMemoryCapGB)) GB"))
        }
        if rule == .idleSessions, !snapshot.underMemoryPressure {
            return make(.keep(reason: "\(idleText)；内存不紧张，先不结束"))
        }
        if idleHours >= threshold { return make(.end(reason: idleText)) }
        return make(.keep(reason: "\(idleText)；满 \(Format.number(threshold)) 小时才结束"))
    }
}

public struct ProcessResult {
    public var candidates: [ProcessCandidate] = []
    public var ended: [ProcessCandidate] = []
    public var failed: [ProcessCandidate] = []
    /// 读不到进程表等原因导致这一轮没有判断。
    public var error: String?

    public var freedBytes: Int64 { ended.reduce(0) { $0 + $1.memory } }
}

public enum ProcessText {
    /// 按规则列出候选进程树：会结束的逐条列出，保留的附上原因。
    public static func list(_ result: ProcessResult, home: String, limitPerRule: Int? = 15) -> String {
        var lines: [String] = []
        for rule in ProcessRule.allCases {
            let items = result.candidates.filter { $0.rule == rule }
            guard !items.isEmpty else { continue }
            let ending = items.filter(\.isEnd).sorted { $0.memory > $1.memory }
            let kept = items.filter { !$0.isEnd }.sorted { $0.memory > $1.memory }
            lines.append("\(rule.title) — 可结束 \(ending.count) 个，\(Format.bytes(ending.reduce(0) { $0 + $1.memory }))")
            for item in limitPerRule.map({ Array(ending.prefix($0)) }) ?? ending { lines.append(row(item, home: home)) }
            if let limit = limitPerRule, ending.count > limit { lines.append("  … 另有 \(ending.count - limit) 个") }
            for item in limitPerRule.map({ Array(kept.prefix($0)) }) ?? kept { lines.append("  保留" + row(item, home: home).dropFirst(1)) }
            if let limit = limitPerRule, kept.count > limit { lines.append("  … 另有 \(kept.count - limit) 个保留") }
            lines.append("")
        }
        if lines.isEmpty { lines.append("没有发现 agent 留下的进程。") }
        return lines.joined(separator: "\n")
    }

    private static func row(_ item: ProcessCandidate, home: String) -> String {
        var command = item.root.command.replacingOccurrences(of: home, with: "~")
        if command.count > 90 { command = String(command.prefix(89)) + "…" }
        let count = item.members.count > 1 ? "（\(item.members.count) 个进程）" : ""
        return "  \(Format.bytes(item.memory).padding(toLength: 8, withPad: " ", startingAt: 0)) pid \(item.root.pid)\(count)  "
            + "\(item.reason)\n             \(command)"
    }

    /// 每条规则结束了几个，如「孤儿残留进程 2、Codex 积压的工具进程 5」。
    public static func summary(_ ended: [ProcessCandidate]) -> String {
        ProcessRule.allCases.compactMap { rule in
            let n = ended.filter { $0.rule == rule }.count
            return n > 0 ? "\(rule.title) \(n)" : nil
        }.joined(separator: "、")
    }
}

/// 观察一次进程表、更新闲置记录，按需结束闲置的进程树。
public struct ProcessReaper {
    let env: Env

    public init(env: Env) { self.env = env }

    public func run(_ config: Config.Processes, end: Bool) -> ProcessResult {
        var result = ProcessResult()
        guard let snapshot = env.processSystem.snapshot() else {
            result.error = "读不到进程表，这一轮不结束任何进程"
            return result
        }
        var watch = ProcessWatch.load(from: env.processesFile)
        watch.observe(snapshot, now: env.now)
        try? watch.save(to: env.processesFile)
        let projects = env.home.appendingPathComponent(".claude/projects")
        let planner = ProcessPlanner(config: config, now: env.now) { project, session in
            let transcript = projects.appendingPathComponent(project).appendingPathComponent("\(session).jsonl")
            return FileKind.info(transcript.path).map { Date(timeIntervalSince1970: $0.mtime) }
        }
        result.candidates = planner.plan(snapshot, watch: watch)

        let targets = result.candidates.filter(\.isEnd)
        guard end, !targets.isEmpty else { return result }

        // 一次性结束所有目标，宽限等待只等一轮；每棵树里子进程在前，免得父进程退出后它们又成了孤儿
        let ended = Set(env.processSystem.end(targets.flatMap { $0.members.reversed() }).map(\.key))
        for candidate in targets {
            let ok = ended.contains(candidate.root.key)
            if ok { result.ended.append(candidate) } else { result.failed.append(candidate) }
            let command = String(candidate.root.command.prefix(160))
            SweepLog.append("\(SweepLog.stamp(env.now)) \(ok ? "END" : "ERROR") \(candidate.rule.rawValue) "
                            + "\(Format.bytes(candidate.memory)) pid \(candidate.root.pid) \(command) — "
                            + (ok ? candidate.reason : "没能结束"), env: env)
        }
        return result
    }
}
