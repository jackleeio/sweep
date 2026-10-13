import Foundation

/// 只读扫描：找出各规则命中的项并给出处置结论，不做任何删除。
public struct Scanner {
    let config: Config
    let env: Env
    let pins: PinStore

    public init(config: Config, env: Env, pins: PinStore) {
        self.config = config
        self.env = env
        self.pins = pins
    }

    public func scan(rules: Set<RuleID> = Set(RuleID.allCases)) -> [Candidate] {
        var out: [Candidate] = []
        if rules.contains(.buildCaches), config.buildCaches.enabled { out += buildCaches() }
        if rules.contains(.agentTemp), config.agentTemp.enabled { out += agentTemp() }
        if rules.contains(.conversations), config.conversations.enabled { out += conversations() }
        if rules.contains(.packageCaches), config.packageCaches.enabled { out += packageCaches() }
        if rules.contains(.artifacts), config.artifacts.enabled { out += artifacts() }
        if rules.contains(.workCopies) { out += workCopies() }
        return out
    }

    // MARK: - 通用

    private func idleDays(_ date: Date) -> Double { env.now.timeIntervalSince(date) / 86400 }

    private func idleReason(_ days: Double) -> String { "\(Int(days)) 天没更新" }

    private func byPath(_ list: [Candidate]) -> [Candidate] { list.sorted { $0.url.path < $1.url.path } }

    // MARK: - 构建缓存

    private static let skippedDirectories: Set<String> = ["node_modules", ".git", "Pods", ".venv", "venv", "__pycache__"]
    private static let maxDepth = 8

    static func isNextCacheName(_ name: String) -> Bool {
        if name == ".next" { return true }
        guard name.hasPrefix(".next-"), name.count > 6 else { return false }
        return name.dropFirst(6).allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
    }

    /// bun 编译中断后留下的临时文件，形如 `.18bcabdfefcfebff-00000000.bun-build`。
    static func isBunBuildName(_ name: String) -> Bool {
        let suffix = ".bun-build"
        guard name.hasPrefix("."), name.hasSuffix(suffix) else { return false }
        let parts = name.dropFirst().dropLast(suffix.count).split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
    }

    private func buildCaches() -> [Candidate] {
        var out: [Candidate] = []
        for root in config.projectRoots.map(env.expand) where FileKind.of(root) == .directory {
            walk(root, depth: 1, root: root, into: &out)
        }
        return byPath(out)
    }

    private func walk(_ dir: URL, depth: Int, root: URL, into out: inout [Candidate]) {
        let fm = FileManager.default
        guard depth <= Self.maxDepth, let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let url = dir.appendingPathComponent(name)
            switch FileKind.of(url) {
            case .file:
                if Self.isBunBuildName(name) {
                    out.append(buildCache(url, kind: .bunBuild, projectDir: dir, root: root))
                }
            case .directory:
                if Self.isNextCacheName(name) {
                    if fm.fileExists(atPath: dir.appendingPathComponent("package.json").path) {
                        out.append(buildCache(url, kind: .next, projectDir: dir, root: root))
                    }
                } else if name == "target", fm.fileExists(atPath: url.appendingPathComponent("CACHEDIR.TAG").path) {
                    // cargo 的产物目录：只清 Tauri 项目里的，其余的跳过不深入
                    if dir.lastPathComponent == "src-tauri" {
                        out.append(buildCache(url, kind: .cargoTarget, projectDir: dir.deletingLastPathComponent(), root: root))
                    }
                } else if !Self.skippedDirectories.contains(name) {
                    walk(url, depth: depth + 1, root: root, into: &out)
                }
            default:
                continue
            }
        }
    }

    private func buildCache(_ url: URL, kind: CacheKind, projectDir: URL, root: URL) -> Candidate {
        let m = Measure.measure(url)
        let cap = Int64(config.buildCaches.sizeCapGB * 1_073_741_824)

        var verdict: Verdict
        if let latest = m.latest {
            let idle = idleDays(latest)
            if idle >= config.idleDays {
                verdict = .delete(reason: idleReason(idle))
            } else if m.bytes > cap {
                verdict = .delete(reason: "超过 \(Format.gb(config.buildCaches.sizeCapGB)) 上限")
            } else {
                verdict = .keep(reason: "最近在用")
            }
        } else {
            verdict = .keep(reason: "无法读取")
        }

        // 准备删除前再过两道保护
        var blocked = false
        if case .delete(let why) = verdict {
            if case .untracked = Git.tracking(of: url) {
                if env.processProbe.isInUse(projectDir: projectDir, kind: kind) {
                    verdict = .keep(reason: "\(why)，但有进程正在使用")
                    blocked = true
                }
            } else {
                verdict = .keep(reason: "含 git 跟踪的文件")
            }
        }
        return Candidate(rule: .buildCaches, url: url, root: root, bytes: m.bytes, lastActivity: m.latest,
                         verdict: verdict, blockedByProcess: blocked)
    }

    // MARK: - Agent 临时构建目录

    private func agentTemp() -> [Candidate] {
        let out = config.agentTemp.globs.flatMap { Glob.expand($0, env: env) }.map { match -> Candidate in
            let m = Measure.measure(match.url)
            return Candidate(rule: .agentTemp, url: match.url, root: match.root, bytes: m.bytes,
                             lastActivity: m.latest, verdict: idleVerdict(m.latest, threshold: config.idleDays))
        }
        return byPath(out)
    }

    private func idleVerdict(_ latest: Date?, threshold: Double) -> Verdict {
        guard let latest else { return .keep(reason: "无法读取") }
        let idle = idleDays(latest)
        return idle >= threshold ? .delete(reason: idleReason(idle)) : .keep(reason: "最近有更新")
    }

    // MARK: - Agent 对话

    private func conversations() -> [Candidate] {
        // nil 表示名单文件损坏：此时一条对话都不能删
        let loaded = try? pins.all()
        var out: [Candidate] = []
        for root in config.conversations.codexRoots.map(env.expand) { out += codexSessions(in: root, pins: loaded) }
        for root in config.conversations.claudeRoots.map(env.expand) { out += claudeSessions(in: root, pins: loaded) }
        return byPath(out)
    }

    private func codexSessions(in root: URL, pins: [Pin]?) -> [Candidate] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Candidate] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), FileKind.of(url) == .file else { continue }
            let m = Measure.measure(url)
            // 文件名以会话 UUID 结尾
            let tail = String(name.dropLast(".jsonl".count).suffix(36))
            let sessionID = UUID(uuidString: tail) != nil ? tail : nil
            out.append(Candidate(rule: .conversations, url: url, root: root, bytes: m.bytes, lastActivity: m.latest,
                                 verdict: conversationVerdict(file: url, sessionID: sessionID, latest: m.latest, pins: pins)))
        }
        return out
    }

    /// Claude 的会话是 `<项目>/<uuid>.jsonl`，可能带一个同名目录存放工具输出。
    /// 只认 UUID 形态的名字，因此同级的 memory/ 等永远不会命中。
    private func claudeSessions(in root: URL, pins: [Pin]?) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        for projectName in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let project = root.appendingPathComponent(projectName)
            guard FileKind.of(project) == .directory else { continue }

            var files: [String: URL] = [:]
            var dirs: [String: URL] = [:]
            for name in (try? fm.contentsOfDirectory(atPath: project.path)) ?? [] {
                let url = project.appendingPathComponent(name)
                switch FileKind.of(url) {
                case .file where name.hasSuffix(".jsonl"):
                    let id = String(name.dropLast(".jsonl".count))
                    if UUID(uuidString: id) != nil { files[id] = url }
                case .directory where UUID(uuidString: name) != nil:
                    dirs[name] = url
                default:
                    continue
                }
            }

            for id in Set(files.keys).union(dirs.keys) {
                let file = files[id]
                let dir = dirs[id]
                let parts = [file, dir].compactMap { $0 }.map(Measure.measure)
                let latest = parts.compactMap(\.latest).max()
                let primary = file ?? dir!
                out.append(Candidate(rule: .conversations, url: primary, extraURLs: file != nil && dir != nil ? [dir!] : [],
                                     root: root, bytes: parts.reduce(0) { $0 + $1.bytes }, lastActivity: latest,
                                     verdict: conversationVerdict(file: primary, sessionID: id, latest: latest, pins: pins)))
            }
        }
        return out
    }

    private func conversationVerdict(file: URL, sessionID: String?, latest: Date?, pins: [Pin]?) -> Verdict {
        guard let latest else { return .keep(reason: "无法读取") }
        let idle = idleDays(latest)
        guard idle >= config.idleDays else { return .keep(reason: "最近有更新") }
        guard let pins else { return .keep(reason: "标记名单读取失败，暂不删除") }
        if let pin = PinStore.match(pins: pins, file: file, sessionID: sessionID) {
            return .keep(reason: "已标记：\(pin.label)")
        }
        return .delete(reason: idleReason(idle))
    }

    // MARK: - 包管理器缓存

    private func packageCaches() -> [Candidate] {
        let measured = config.packageCaches.paths.map(env.expand)
            .filter { FileKind.of($0) == .directory }
            .map { ($0, Measure.measure($0)) }
        let total = measured.reduce(Int64(0)) { $0 + $1.1.bytes }
        let cap = Int64(config.packageCaches.totalCapGB * 1_073_741_824)
        let capText = Format.gb(config.packageCaches.totalCapGB)
        let verdict: Verdict = total > cap
            ? .delete(reason: "包缓存合计 \(Format.bytes(total))，超过 \(capText) 上限")
            : .keep(reason: "包缓存合计 \(Format.bytes(total))，未到 \(capText) 上限")
        return byPath(measured.map { url, m in
            // 根取 home 并要求至少两层深，防止配置写错时删到 ~/Library 这类目录
            Candidate(rule: .packageCaches, url: url, root: env.home, minDepth: 2, bytes: m.bytes,
                      lastActivity: m.latest, verdict: verdict)
        })
    }

    // MARK: - Agent 生成的产物

    private func artifacts() -> [Candidate] {
        var out: [Candidate] = []
        for root in config.artifacts.paths.map(env.expand) {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where FileKind.of(url) == .file {
                let m = Measure.measure(url)
                out.append(Candidate(rule: .artifacts, url: url, root: root, bytes: m.bytes, lastActivity: m.latest,
                                     verdict: idleVerdict(m.latest, threshold: config.artifacts.idleDays)))
            }
        }
        return byPath(out)
    }

    // MARK: - 工作副本（仅展示）

    private func workCopies() -> [Candidate] {
        let out = config.workCopies.globs.flatMap { Glob.expand($0, env: env) }
            .filter { FileKind.of($0.url) == .directory }
            .map { match -> Candidate in
                let m = Measure.measure(match.url)
                return Candidate(rule: .workCopies, url: match.url, root: match.root, bytes: m.bytes,
                                 lastActivity: m.latest, verdict: .keep(reason: "仅展示，不自动清理"))
            }
        return byPath(out)
    }
}
