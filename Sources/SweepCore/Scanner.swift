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
        // 各规则扫描的目录互不重叠，并行跑；结果仍按规则顺序排列
        RuleID.allCases.filter { rules.contains($0) && isEnabled($0) }
            .parallelMap(candidates(for:))
            .flatMap { $0 }
    }

    private func isEnabled(_ rule: RuleID) -> Bool {
        switch rule {
        case .buildCaches: return config.buildCaches.enabled
        case .agentTemp: return config.agentTemp.enabled
        case .conversations: return config.conversations.enabled
        case .packageCaches: return config.packageCaches.enabled
        case .artifacts: return config.artifacts.enabled
        case .workCopies: return true
        }
    }

    private func candidates(for rule: RuleID) -> [Candidate] {
        switch rule {
        case .buildCaches: return buildCaches()
        case .agentTemp: return agentTemp()
        case .conversations: return conversations()
        case .packageCaches: return packageCaches()
        case .artifacts: return artifacts()
        case .workCopies: return workCopies()
        }
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

    private struct CacheMatch {
        let url: URL
        let kind: CacheKind
        let projectDir: URL
        let root: URL
    }

    private func buildCaches() -> [Candidate] {
        let fm = FileManager.default
        var matches: [CacheMatch] = []
        for root in config.projectRoots.map(env.expand) where FileKind.of(root) == .directory {
            // 根目录下的各个项目并行遍历
            let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
            matches += names.parallelMap { name -> [CacheMatch] in
                var found: [CacheMatch] = []
                visit(name, in: root, depth: 1, root: root, into: &found)
                return found
            }.flatMap { $0 }
        }

        // 测量体积和查 git 是最慢的部分，并行做；进程占用检测有内部状态，留到后面串行做
        let judged = matches.parallelMap { match -> (CacheMatch, Measurement, Verdict, Git.Tracking?) in
            let m = Measure.measure(match.url)
            let verdict = cacheVerdict(m)
            if case .delete = verdict { return (match, m, verdict, Git.tracking(of: match.url)) }
            return (match, m, verdict, nil)
        }

        return byPath(judged.map { match, m, preliminary, tracking in
            var verdict = preliminary
            var blocked = false
            // 准备删除前再过两道保护
            if case .delete(let why) = verdict {
                if case .untracked? = tracking {
                    if env.processProbe.isInUse(projectDir: match.projectDir, kind: match.kind) {
                        verdict = .keep(reason: "\(why)，但有进程正在使用")
                        blocked = true
                    }
                } else {
                    verdict = .keep(reason: "含 git 跟踪的文件")
                }
            }
            return Candidate(rule: .buildCaches, url: match.url, root: match.root, bytes: m.bytes, lastActivity: m.latest,
                             verdict: verdict, blockedByProcess: blocked)
        })
    }

    private func walk(_ dir: URL, depth: Int, root: URL, into out: inout [CacheMatch]) {
        guard depth <= Self.maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names { visit(name, in: dir, depth: depth, root: root, into: &out) }
    }

    private func visit(_ name: String, in dir: URL, depth: Int, root: URL, into out: inout [CacheMatch]) {
        let fm = FileManager.default
        let url = dir.appendingPathComponent(name)
        switch FileKind.of(url) {
        case .file:
            if Self.isBunBuildName(name) {
                out.append(CacheMatch(url: url, kind: .bunBuild, projectDir: dir, root: root))
            }
        case .directory:
            if Self.isNextCacheName(name) {
                if fm.fileExists(atPath: dir.appendingPathComponent("package.json").path) {
                    out.append(CacheMatch(url: url, kind: .next, projectDir: dir, root: root))
                }
            } else if name == "target", fm.fileExists(atPath: url.appendingPathComponent("CACHEDIR.TAG").path) {
                // cargo 的产物目录：只清 Tauri 项目里的，其余的跳过不深入
                if dir.lastPathComponent == "src-tauri" {
                    out.append(CacheMatch(url: url, kind: .cargoTarget, projectDir: dir.deletingLastPathComponent(), root: root))
                }
            } else if !Self.skippedDirectories.contains(name) {
                walk(url, depth: depth + 1, root: root, into: &out)
            }
        default:
            return
        }
    }

    private func cacheVerdict(_ m: Measurement) -> Verdict {
        guard let latest = m.latest else { return .keep(reason: "无法读取") }
        let idle = idleDays(latest)
        if idle >= config.idleDays { return .delete(reason: idleReason(idle)) }
        if m.bytes > Int64(config.buildCaches.sizeCapGB * 1_073_741_824) {
            return .delete(reason: "超过 \(Format.gb(config.buildCaches.sizeCapGB)) 上限")
        }
        return .keep(reason: "最近在用")
    }

    // MARK: - Agent 临时构建目录

    private func agentTemp() -> [Candidate] {
        let out = config.agentTemp.globs.flatMap { Glob.expand($0, env: env) }.parallelMap { match -> Candidate in
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
        var files: [URL] = []
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl"), FileKind.of(url) == .file { files.append(url) }
        }
        // 判定时可能要通读文件找标记串，并行做
        return files.parallelMap { url in
            let m = Measure.measure(url)
            // 文件名以会话 UUID 结尾
            let tail = String(url.lastPathComponent.dropLast(".jsonl".count).suffix(36))
            let sessionID = UUID(uuidString: tail) != nil ? tail : nil
            return Candidate(rule: .conversations, url: url, root: root, bytes: m.bytes, lastActivity: m.latest,
                             verdict: conversationVerdict(file: url, sessionID: sessionID, latest: m.latest, pins: pins))
        }
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

            out += Set(files.keys).union(dirs.keys).sorted().parallelMap { id in
                let file = files[id]
                let dir = dirs[id]
                let parts = [file, dir].compactMap { $0 }.map(Measure.measure)
                let latest = parts.compactMap(\.latest).max()
                let primary = file ?? dir!
                return Candidate(rule: .conversations, url: primary, extraURLs: file != nil && dir != nil ? [dir!] : [],
                                 root: root, bytes: parts.reduce(0) { $0 + $1.bytes }, lastActivity: latest,
                                 verdict: conversationVerdict(file: primary, sessionID: id, latest: latest, pins: pins))
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
            .parallelMap { ($0, Measure.measure($0)) }
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
            .parallelMap { match -> Candidate in
                let m = Measure.measure(match.url)
                return Candidate(rule: .workCopies, url: match.url, root: match.root, bytes: m.bytes,
                                 lastActivity: m.latest, verdict: .keep(reason: "仅展示，不自动清理"))
            }
        return byPath(out)
    }
}
