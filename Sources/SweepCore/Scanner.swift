import Foundation

/// 只读扫描：找出各规则命中的项并给出处置结论，不做任何删除。
public struct Scanner {
    let config: Config
    let env: Env
    let pins: PinStore
    /// 收紧模式：空间不足时使用。缓存类规则从「3 天没更新」收紧到「1 小时没更新」，
    /// 包缓存不看上限，闲置依赖的门槛降到 3 天。对话规则不受影响。
    let tight: Bool

    /// 把关着的规则也一并量出来，仅用于展示。清理流程永远不会带这个参数。
    let includeDisabled: Bool

    public init(config: Config, env: Env, pins: PinStore, tight: Bool = false, includeDisabled: Bool = false) {
        self.config = config
        self.env = env
        self.pins = pins
        self.tight = tight
        self.includeDisabled = includeDisabled
    }

    public func scan(rules: Set<RuleID> = Set(RuleID.allCases)) -> [Candidate] {
        let active = RuleID.allCases.filter { rules.contains($0) && isEnabled($0) }
        // 构建缓存和依赖目录都在项目目录里，共用一次遍历
        let needsProjects = active.contains(.buildCaches) || active.contains(.dependencies)
        let projects = needsProjects ? walkProjects() : ProjectMatches()
        // 各规则扫描的目录互不重叠，并行跑；结果仍按规则顺序排列
        let found = active.parallelMap { candidates(for: $0, projects: projects) }.flatMap { $0 }
        return applyExcludes(found)
    }

    /// 这条规则要不要扫描。工作副本和大户始终列出：前者是否真的移除由它自己的开关决定，后者只展示。
    private func isEnabled(_ rule: RuleID) -> Bool {
        includeDisabled || rule == .workCopies || rule == .bigItems || config.isEnabled(rule)
    }

    private func candidates(for rule: RuleID, projects: ProjectMatches) -> [Candidate] {
        switch rule {
        case .buildCaches: return buildCaches(projects.caches)
        case .dependencies: return dependencies(projects.dependencies)
        case .workCopies: return workCopies()
        case .agentTemp: return agentTemp()
        case .conversations: return conversations()
        case .claudeConversations: return claudeConversations()
        case .packageCaches: return packageCaches()
        case .appCaches: return appCaches()
        case .artifacts: return artifacts()
        case .recordings: return recordings()
        case .bigItems: return bigItems()
        }
    }

    // MARK: - 通用

    /// 缓存类规则的闲置门槛（天）。
    private var cacheIdleDays: Double { tight ? 1.0 / 24 : config.idleDays }

    private func idleDays(_ date: Date) -> Double { env.now.timeIntervalSince(date) / 86400 }

    private func idleReason(_ days: Double) -> String {
        days < 1 ? "\(Int(days * 24)) 小时没更新" : "\(Int(days)) 天没更新"
    }

    private func byPath(_ list: [Candidate]) -> [Candidate] { list.sorted { $0.url.path < $1.url.path } }

    private func idleVerdict(_ m: Measurement, threshold: Double) -> Verdict {
        if m.unreadable { return .keep(reason: "无法完整读取") }
        guard let latest = m.latest else { return .keep(reason: "无法读取") }
        let idle = idleDays(latest)
        return idle >= threshold ? .delete(reason: idleReason(idle)) : .keep(reason: "最近有更新")
    }

    /// 去掉与排除路径有重叠的项：在排除路径内部的，以及把排除路径包在里面的。
    private func applyExcludes(_ list: [Candidate]) -> [Candidate] {
        let excluded = config.excludes.map { Self.plainPath(env.expand($0)) }
        guard !excluded.isEmpty else { return list }
        return list.filter { candidate in
            !([candidate.url] + candidate.extraURLs).map(Self.plainPath).contains { path in
                excluded.contains { $0 == path || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
        }
    }

    /// 去掉结尾斜杠的路径。不用 standardizedFileURL：它对存在和不存在的路径处理不一致
    /// （存在时会去掉 /private 前缀），两边比较会对不上。
    private static func plainPath(_ url: URL) -> String {
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: - 项目目录遍历

    private struct CacheMatch {
        let url: URL
        let kind: CacheKind
        let projectDir: URL
        let root: URL
    }

    private struct DependencyMatch {
        let url: URL
        /// 所属项目：最近的 git 仓库，没有仓库时取根目录下的顶层目录。
        let project: URL
        let root: URL
        /// 项目最近一次改动的时间（依赖目录内部的文件不算）。
        let activity: Double
    }

    private struct ProjectMatches {
        var caches: [CacheMatch] = []
        var dependencies: [DependencyMatch] = []
    }

    private static let skippedDirectories: Set<String> = ["Pods", "__pycache__", ".venv", "venv"]
    private static let rebuildManifests: Set<String> = ["uv.lock", "poetry.lock", "Pipfile.lock", "pyproject.toml"]
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

    private func walkProjects() -> ProjectMatches {
        var all = ProjectMatches()
        for root in config.projectRoots.map(env.expand) where FileKind.of(root) == .directory {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            // 根目录下的各个项目并行遍历
            let parts = names.parallelMap { name -> ProjectMatches in
                var found = ProjectMatches()
                let path = root.path + "/" + name
                guard let info = FileKind.info(path) else { return found }
                if info.kind == .file, Self.isBunBuildName(name) {
                    found.caches.append(CacheMatch(url: URL(fileURLWithPath: path), kind: .bunBuild, projectDir: root, root: root))
                } else if info.kind == .directory, name != "node_modules", !Self.skippedDirectories.contains(name) {
                    _ = walk(path, depth: 1, root: root, into: &found)
                }
                return found
            }
            for part in parts {
                all.caches += part.caches
                all.dependencies += part.dependencies
            }
        }
        return all
    }

    /// 遍历一个目录，把命中的缓存和依赖目录记入 out。
    /// 返回该目录下项目文件的最新修改时间，以及还没归到某个项目名下的依赖目录。
    /// 这里用字符串路径而不是 URL：要访问的条目很多，URL 的拼接开销明显。
    private func walk(_ dir: String, depth: Int, root: URL, into out: inout ProjectMatches) -> (latest: Double, pending: [String]) {
        var latest = FileKind.info(dir)?.mtime ?? 0
        var pending: [String] = []
        guard depth <= Self.maxDepth, let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return (latest, pending)
        }
        let siblings = Set(names)
        let dirURL = URL(fileURLWithPath: dir)

        for name in names where name != ".DS_Store" {
            let path = dir + "/" + name
            guard let info = FileKind.info(path) else { continue }
            guard info.kind == .directory else {
                if info.kind == .file, Self.isBunBuildName(name) {
                    out.caches.append(CacheMatch(url: URL(fileURLWithPath: path), kind: .bunBuild, projectDir: dirURL, root: root))
                } else {
                    latest = max(latest, info.mtime)
                }
                continue
            }

            if Self.isNextCacheName(name) {
                if siblings.contains("package.json") {
                    out.caches.append(CacheMatch(url: URL(fileURLWithPath: path), kind: .next, projectDir: dirURL, root: root))
                }
            } else if name == "target", FileKind.info(path + "/CACHEDIR.TAG") != nil {
                // cargo 的产物目录：只清 Tauri 项目里的，其余的跳过不深入
                if dirURL.lastPathComponent == "src-tauri" {
                    out.caches.append(CacheMatch(url: URL(fileURLWithPath: path), kind: .cargoTarget,
                                                 projectDir: dirURL.deletingLastPathComponent(), root: root))
                }
            } else if name == "node_modules" {
                if siblings.contains("package.json") {
                    pending.append(path)
                    // 最近装过依赖也算项目有动静，否则刚 install 完就会被清掉
                    latest = max(latest, shallowLatest(path))
                }
            } else if name == ".venv" || name == "venv", FileKind.info(path + "/pyvenv.cfg") != nil {
                // 只有能照原样重建的虚拟环境才清
                if !siblings.isDisjoint(with: Self.rebuildManifests) || siblings.contains(where: { $0.hasPrefix("requirements") && $0.hasSuffix(".txt") }) {
                    pending.append(path)
                    latest = max(latest, virtualEnvLatest(path))
                }
            } else if name == ".git" {
                latest = max(latest, gitLatest(path))
            } else if !Self.skippedDirectories.contains(name) {
                let inner = walk(path, depth: depth + 1, root: root, into: &out)
                latest = max(latest, inner.latest)
                pending += inner.pending
            }
        }

        // 项目边界：git 仓库或工作树（.git 是目录或文件），或根目录下的顶层目录。
        // 同一仓库里的包共用仓库的活跃时间，避免只清掉 monorepo 的一部分。
        if siblings.contains(".git") || depth == 1 {
            for path in pending {
                out.dependencies.append(DependencyMatch(url: URL(fileURLWithPath: path), project: dirURL, root: root, activity: latest))
            }
            pending = []
        }
        return (latest, pending)
    }

    /// 目录自身及其直接子项的最新修改时间。
    private func shallowLatest(_ dir: String) -> Double {
        var latest = FileKind.info(dir)?.mtime ?? 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            latest = max(latest, FileKind.info(dir + "/" + name)?.mtime ?? 0)
        }
        return latest
    }

    private func virtualEnvLatest(_ dir: String) -> Double {
        var latest = FileKind.info(dir)?.mtime ?? 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir + "/lib")) ?? [] {
            latest = max(latest, FileKind.info(dir + "/lib/" + name + "/site-packages")?.mtime ?? 0)
        }
        return latest
    }

    /// 提交、暂存、切换分支、拉取都会更新这几个文件。
    private func gitLatest(_ gitDir: String) -> Double {
        ["", "/index", "/HEAD", "/logs/HEAD", "/FETCH_HEAD", "/ORIG_HEAD"]
            .compactMap { FileKind.info(gitDir + $0)?.mtime }
            .max() ?? 0
    }

    // MARK: - 构建缓存

    private func buildCaches(_ matches: [CacheMatch]) -> [Candidate] {
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

    private func cacheVerdict(_ m: Measurement) -> Verdict {
        if m.unreadable { return .keep(reason: "无法完整读取") }
        guard let latest = m.latest else { return .keep(reason: "无法读取") }
        let idle = idleDays(latest)
        if idle >= cacheIdleDays { return .delete(reason: idleReason(idle)) }
        if m.bytes > Int64(config.buildCaches.sizeCapGB * Format.gigabyte) {
            return .delete(reason: "超过 \(Format.gb(config.buildCaches.sizeCapGB)) 上限")
        }
        return .keep(reason: "最近在用")
    }

    // MARK: - 闲置项目的依赖

    private func dependencies(_ matches: [DependencyMatch]) -> [Candidate] {
        let threshold = tight ? config.idleDays : config.dependencies.idleDays

        let judged = matches.parallelMap { match -> (DependencyMatch, Measurement, Verdict, Git.Tracking?) in
            let m = Measure.measure(match.url)
            let idle = (env.now.timeIntervalSince1970 - match.activity) / 86400
            let verdict: Verdict
            if m.unreadable {
                verdict = .keep(reason: "无法完整读取")
            } else if idle >= threshold {
                verdict = .delete(reason: "项目 \(Int(idle)) 天没动，依赖可重新安装")
            } else {
                verdict = .keep(reason: "项目最近有改动")
            }
            if case .delete = verdict { return (match, m, verdict, Git.tracking(of: match.url)) }
            return (match, m, verdict, nil)
        }

        // 全局 link 的命令、技能链接、定时任务会在项目「闲置」时照样用到它的依赖
        let references = env.externalReferences().map { $0.lowercased() }

        return byPath(judged.map { match, m, preliminary, tracking in
            var verdict = preliminary
            if case .delete = verdict {
                let project = (realPath(match.project) ?? match.project.path).lowercased()
                if references.contains(where: { $0 == project || $0.hasPrefix(project + "/") }) {
                    verdict = .keep(reason: "被全局命令、技能或定时任务引用")
                } else if case .untracked? = tracking {
                    if env.processProbe.isInUse(projectDir: match.project, kind: .dependencies) {
                        verdict = .keep(reason: "项目里有进程在运行")
                    }
                } else {
                    verdict = .keep(reason: "含 git 跟踪的文件")
                }
            }
            return Candidate(rule: .dependencies, url: match.url, root: match.root, bytes: m.bytes,
                             lastActivity: Date(timeIntervalSince1970: match.activity), verdict: verdict)
        })
    }

    // MARK: - Agent 临时构建目录

    private func agentTemp() -> [Candidate] {
        let out = config.agentTemp.globs.flatMap { Glob.expand($0, env: env) }.parallelMap { match -> Candidate in
            let m = Measure.measure(match.url)
            return Candidate(rule: .agentTemp, url: match.url, root: match.root, bytes: m.bytes,
                             lastActivity: m.latest, verdict: idleVerdict(m, threshold: cacheIdleDays))
        }
        return byPath(out)
    }

    // MARK: - 对话：通用

    /// 按闲置天数分档，界面上按档显示。
    static func ageBucket(_ idle: Double) -> String {
        if idle < 3 { return "3 天内更新过" }
        if idle < 7 { return "3–7 天没更新" }
        if idle < 30 { return "7–30 天没更新" }
        if idle < 90 { return "30–90 天没更新" }
        return "90 天以上没更新"
    }

    /// 准备删除某条对话前的最后一步：查用户用 `sweep keep` 打的标记。
    /// 对话规则不受收紧模式影响：空间再紧张也不加快删除对话。
    private func unlessMarked(_ verdict: Verdict, _ category: String, file: URL, sessionID: String?, pins: [Pin]?) -> (Verdict, String) {
        guard case .delete = verdict else { return (verdict, category) }
        guard let pins else { return (.keep(reason: "标记名单读取失败，暂不删除"), "无法判断") }
        if let pin = PinStore.match(pins: pins, file: file, sessionID: sessionID) {
            return (.keep(reason: "已标记：\(pin.label)"), "已标记")
        }
        return (verdict, category)
    }

    // MARK: - Codex 对话

    private struct CodexSession {
        let url: URL
        let root: URL
        let bytes: Int64
        let latest: Date?
        let id: String?
        let thread: CodexIndex.Thread?
        let archived: Bool
        /// Codex 会把旧会话压缩成 .jsonl.zst，里面的内容没法直接搜索。
        let compressed: Bool
    }

    private static let compressedSuffix = ".zst"

    private func conversations() -> [Candidate] {
        // nil 表示名单文件损坏：此时一条对话都不能删
        let loadedPins = try? pins.all()
        // sessions 和 archived_sessions 在同一个 Codex 目录下，共用一份状态
        let roots = config.conversations.codexRoots.map(env.expand)
        let byHome = Dictionary(grouping: roots) { $0.deletingLastPathComponent().path }
        return byPath(byHome.flatMap { home, roots in
            codexSessions(home: URL(fileURLWithPath: home), roots: roots, pins: loadedPins)
        })
    }

    private func codexSessions(home: URL, roots: [URL], pins loadedPins: [Pin]?) -> [Candidate] {
        var files: [(url: URL, root: URL)] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl" + Self.compressedSuffix),
                      FileKind.of(url) == .file else { continue }
                files.append((url, root))
            }
        }
        guard !files.isEmpty else { return [] }

        // 读不懂 Codex 的状态就无从知道哪些被置顶了，这时一条都不删
        let index = try? CodexIndex.load(codexHome: home)

        let sessions = files.parallelMap { file -> CodexSession in
            let m = Measure.measure(file.url)
            let compressed = file.url.path.hasSuffix(Self.compressedSuffix)
            // 压缩后数据库里登记的仍是不带 .zst 的路径
            let recorded = compressed ? String(file.url.path.dropLast(Self.compressedSuffix.count)) : file.url.path
            let thread = index?.byPath[recorded]
            // 文件名以对话的 UUID 结尾；数据库里没有记录时用它来对置顶名单
            let tail = String(URL(fileURLWithPath: recorded).lastPathComponent.dropLast(".jsonl".count).suffix(36))
            let id = thread?.id ?? (UUID(uuidString: tail) != nil ? tail.lowercased() : nil)
            return CodexSession(url: file.url, root: file.root, bytes: m.bytes,
                                latest: [m.latest, thread?.updatedAt].compactMap { $0 }.max(), id: id, thread: thread,
                                archived: thread?.archived == true || file.root.lastPathComponent == "archived_sessions",
                                compressed: compressed)
        }

        func candidate(_ s: CodexSession, _ verdict: Verdict, _ category: String) -> Candidate {
            Candidate(rule: .conversations, url: s.url, root: s.root, bytes: s.bytes, lastActivity: s.latest,
                      verdict: verdict, category: category)
        }
        guard let index else {
            return sessions.map { candidate($0, .keep(reason: "读不懂 Codex 的状态，无法确认哪些对话被置顶，暂不删除"), "无法判断") }
        }

        let marks = loadedPins.map { bindMarks($0, to: sessions) }

        func isSubagent(_ s: CodexSession) -> Bool {
            s.thread?.isSubagent == true || s.id.map { index.parentOf[$0] != nil } == true
        }
        // 先判定普通对话（可能要通读文件找标记串，并行做）
        let judged = sessions.filter { !isSubagent($0) }.parallelMap { s -> (CodexSession, Verdict, String) in
            let (verdict, category) = codexVerdict(s, index: index, pins: marks)
            return (s, verdict, category)
        }
        var verdictOf: [String: Verdict] = [:]
        for (s, verdict, _) in judged { if let id = s.id { verdictOf[id] = verdict } }
        var out = judged.map { candidate($0.0, $0.1, $0.2) }

        // 子 agent 的会话跟随所属对话：所属对话保留它就保留，所属对话清理它也清理
        for s in sessions where isSubagent(s) {
            if let owner = s.id.flatMap(index.rootConversation), let ownerVerdict = verdictOf[owner] {
                if case .delete = ownerVerdict {
                    out.append(candidate(s, .delete(reason: "子 agent 的会话，所属对话已可清理"), "子 agent 的会话"))
                } else {
                    out.append(candidate(s, .keep(reason: "所属对话保留"), "子 agent（所属对话保留）"))
                }
            } else if let latest = s.latest, idleDays(latest) >= config.conversations.idleDays {
                // 所属对话已经不在了，按它自己的闲置时间算
                out.append(candidate(s, .delete(reason: "子 agent 的会话，\(idleReason(idleDays(latest)))"), "子 agent 的会话"))
            } else {
                out.append(candidate(s, .keep(reason: "最近有更新"), "子 agent（最近有更新）"))
            }
        }
        return out
    }

    /// 趁会话文件还没被压缩，把 `sweep keep` 的标记串对上会话 ID 并存进名单。
    /// 返回更新后的名单。只看标记之后还有过更新的未压缩文件，通常没几个。
    private func bindMarks(_ loaded: [Pin], to sessions: [CodexSession]) -> [Pin] {
        let unbound = loaded.filter { $0.sessionID == nil }
        guard let earliest = unbound.map(\.createdAt).min() else { return loaded }
        let tokens = Set(unbound.map(\.token))

        let found = sessions.filter { !$0.compressed && $0.id != nil && ($0.latest ?? .distantPast) >= earliest }
            .parallelMap { s in (s.id!, TokenScanner.tokens(in: s.url).intersection(tokens)) }
        var sessionIDs: [String: String] = [:]
        for (id, hits) in found { for token in hits { sessionIDs[token] = id } }
        guard !sessionIDs.isEmpty else { return loaded }

        try? pins.bind(sessionIDs)
        return loaded.map { pin in
            var pin = pin
            if pin.sessionID == nil, let id = sessionIDs[pin.token] { pin.sessionID = id }
            return pin
        }
    }

    private func codexVerdict(_ s: CodexSession, index: CodexIndex, pins: [Pin]?) -> (Verdict, String) {
        if let id = s.id {
            if index.isPinned(id) { return (.keep(reason: "Codex 里 pin 的"), "Codex 里 pin 的") }
            if index.isInPinnedProject(id) { return (.keep(reason: "在 Codex 置顶的项目里"), "在置顶项目里的") }
        }
        guard let latest = s.latest else { return (.keep(reason: "无法读取"), "无法判断") }
        let idle = idleDays(latest)
        let bucket = Self.ageBucket(idle)

        let preliminary: (Verdict, String)
        if s.archived {
            // 归档是用户明确表示「不要了」，不必等满一周，安静几天即可
            guard idle >= config.idleDays else { return (.keep(reason: "已归档，但最近还有更新"), bucket) }
            preliminary = (.delete(reason: "已归档，\(idleReason(idle))"), "已归档")
        } else {
            guard idle >= config.conversations.idleDays else { return (.keep(reason: "最近有更新"), bucket) }
            if index.hasDatabase, s.thread == nil {
                preliminary = (.delete(reason: "Codex 里没有这条对话的记录，\(idleReason(idle))"), "Codex 里没有记录")
            } else {
                preliminary = (.delete(reason: idleReason(idle)), bucket)
            }
        }

        guard s.compressed else {
            return unlessMarked(preliminary.0, preliminary.1, file: s.url, sessionID: s.id, pins: pins)
        }
        // 压缩文件里搜不到标记串，只能按会话 ID 认
        guard let pins else { return (.keep(reason: "标记名单读取失败，暂不删除"), "无法判断") }
        if let id = s.id, let pin = pins.first(where: { $0.sessionID == id }) {
            return (.keep(reason: "已标记：\(pin.label)"), "已标记")
        }
        // 还没对上号的标记：只要这个文件在标记之后还更新过，就有可能是它，不删
        if pins.contains(where: { $0.sessionID == nil && $0.createdAt <= latest }) {
            return (.keep(reason: "可能是被标记的对话（已压缩，无法确认）"), "无法判断")
        }
        return preliminary
    }

    // MARK: - Claude 对话

    /// Claude 的会话是 `<项目>/<uuid>.jsonl`，可能带一个同名目录存放工具输出。
    /// 只认 UUID 形态的名字，因此同级的 memory/ 等永远不会命中。
    private func claudeConversations() -> [Candidate] {
        let loadedPins = try? pins.all()
        let fm = FileManager.default
        var out: [Candidate] = []
        for root in config.claudeConversations.claudeRoots.map(env.expand) {
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
                    // 有读不了的部分时，按「刚更新过」处理，不删
                    let latest = parts.contains(where: \.unreadable) ? env.now : parts.compactMap(\.latest).max()
                    let primary = file ?? dir!
                    let (verdict, category) = claudeVerdict(file: primary, sessionID: id, latest: latest, pins: loadedPins)
                    return Candidate(rule: .claudeConversations, url: primary, extraURLs: file != nil && dir != nil ? [dir!] : [],
                                     root: root, bytes: parts.reduce(0) { $0 + $1.bytes }, lastActivity: latest,
                                     verdict: verdict, category: category)
                }
            }
        }
        return byPath(out)
    }

    private func claudeVerdict(file: URL, sessionID: String, latest: Date?, pins: [Pin]?) -> (Verdict, String) {
        guard let latest else { return (.keep(reason: "无法读取"), "无法判断") }
        let idle = idleDays(latest)
        let bucket = Self.ageBucket(idle)
        guard idle >= config.claudeConversations.idleDays else { return (.keep(reason: "最近有更新"), bucket) }
        return unlessMarked(.delete(reason: idleReason(idle)), bucket, file: file, sessionID: sessionID, pins: pins)
    }

    // MARK: - 包与工具缓存

    private func packageCaches() -> [Candidate] {
        let measured = config.packageCaches.paths.map(env.expand)
            .filter { FileKind.of($0) == .directory }
            .parallelMap { ($0, Measure.measure($0)) }
        let total = measured.reduce(Int64(0)) { $0 + $1.1.bytes }
        let cap = tight ? 0 : Int64(config.packageCaches.totalCapGB * Format.gigabyte)
        let capText = Format.gb(config.packageCaches.totalCapGB)

        let verdict: Verdict
        if total <= cap {
            verdict = .keep(reason: "包缓存合计 \(Format.bytes(total))，未到 \(capText) 上限")
        } else if tight {
            verdict = .delete(reason: "空间不足，清空包缓存")
        } else {
            verdict = .delete(reason: "包缓存合计 \(Format.bytes(total))，超过 \(capText) 上限")
        }
        return byPath(measured.map { url, m in
            // 根取 home 并要求至少两层深，防止配置写错时删到 ~/Library 这类目录
            Candidate(rule: .packageCaches, url: url, root: env.home, minDepth: 2, bytes: m.bytes, lastActivity: m.latest,
                      verdict: m.unreadable ? .keep(reason: "无法完整读取") : verdict)
        })
    }

    // MARK: - 应用缓存

    private func appCaches() -> [Candidate] {
        // 已经归其他规则管的目录不重复列出
        let owned = Set(config.packageCaches.paths.map { Self.plainPath(env.expand($0)) }
            + config.agentTemp.globs.flatMap { Glob.expand($0, env: env) }.map { Self.plainPath($0.url) })

        var entries: [(url: URL, root: URL)] = []
        for root in config.appCaches.roots.map(env.expand) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] {
                guard !name.hasPrefix("."), !config.appCaches.skipPrefixes.contains(where: name.hasPrefix) else { continue }
                let url = root.appendingPathComponent(name)
                guard let kind = FileKind.of(url), kind == .directory || kind == .file,
                      !owned.contains(Self.plainPath(url)) else { continue }
                entries.append((url, root))
            }
        }
        return byPath(entries.parallelMap { entry in
            let m = Measure.measure(entry.url)
            let name = entry.url.lastPathComponent.lowercased()
            // AI 工具和 agent 的缓存默认保留，但仍然列出，让用户看得到占了多少
            let isAITool = Config.AppCaches.aiToolKeywords.contains(where: name.contains)
            let verdict: Verdict = config.appCaches.keepAITools && isAITool
                ? .keep(reason: "AI 工具的缓存，按设置保留")
                : idleVerdict(m, threshold: cacheIdleDays)
            return Candidate(rule: .appCaches, url: entry.url, root: entry.root, bytes: m.bytes,
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
                                     verdict: idleVerdict(m, threshold: config.artifacts.idleDays)))
            }
        }
        return byPath(out)
    }

    // MARK: - 历史录音

    private func recordings() -> [Candidate] {
        var out: [Candidate] = []
        for root in config.recordings.paths.map(env.expand) {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where FileKind.of(url) == .file && !url.lastPathComponent.hasPrefix(".") {
                let m = Measure.measure(url)
                out.append(Candidate(rule: .recordings, url: url, root: root, bytes: m.bytes, lastActivity: m.latest,
                                     verdict: idleVerdict(m, threshold: config.recordings.idleDays)))
            }
        }
        return byPath(out)
    }

    // MARK: - 工作副本

    private func workCopies() -> [Candidate] {
        let matches = config.workCopies.globs.flatMap { Glob.expand($0, env: env) }.filter { FileKind.of($0.url) == .directory }
        return byPath(matches.parallelMap { match -> Candidate in
            let m = Measure.measure(match.url)
            let (verdict, post): (Verdict, PostDelete?) = config.workCopies.enabled || includeDisabled
                ? worktreeVerdict(match.url, m)
                : (.keep(reason: "仅展示，不自动清理"), nil)
            return Candidate(rule: .workCopies, url: match.url, root: match.root, bytes: m.bytes,
                             lastActivity: m.latest, verdict: verdict, postDelete: post)
        })
    }

    /// 只有满足全部条件的 git 工作树才移除：干净、够久没动、提交还能从某个分支找到。
    /// 移除的只是检出的那份文件，分支和提交都留在主仓库里。
    private func worktreeVerdict(_ url: URL, _ m: Measurement) -> (Verdict, PostDelete?) {
        guard FileKind.of(url.appendingPathComponent(".git")) == .file else {
            return (.keep(reason: "不是 git 工作树，无法确认里面有没有独有的改动"), nil)
        }
        if m.unreadable { return (.keep(reason: "无法完整读取"), nil) }
        guard let latest = m.latest else { return (.keep(reason: "无法读取"), nil) }
        let idle = idleDays(latest)
        guard idle >= config.workCopies.idleDays else { return (.keep(reason: "最近有改动"), nil) }

        guard let status = Git.output(["-C", url.path, "status", "--porcelain"]) else {
            return (.keep(reason: "读不出 git 状态"), nil)
        }
        guard status.isEmpty else { return (.keep(reason: "有未提交的改动"), nil) }

        // 游离 HEAD 上的提交如果不属于任何分支，移除后就找不回来了
        let branches = (Git.output(["-C", url.path, "branch", "-a", "--contains", "HEAD"]) ?? "")
            .split(separator: "\n").filter { !$0.contains("HEAD detached") && !$0.contains("(no branch") }
        guard !branches.isEmpty else { return (.keep(reason: "当前提交不在任何分支上"), nil) }

        guard let common = Git.output(["-C", url.path, "rev-parse", "--path-format=absolute", "--git-common-dir"]),
              common.hasSuffix("/.git") else { return (.keep(reason: "找不到所属的主仓库"), nil) }
        let main = URL(fileURLWithPath: String(common.dropLast("/.git".count)))
        return (.delete(reason: "干净的 git 工作树，\(Int(idle)) 天没动；分支保留在 \(main.lastPathComponent)"),
                .pruneWorktrees(mainRepository: main))
    }

    // MARK: - 其他大户（仅展示）

    private func bigItems() -> [Candidate] {
        Config.BigItems.builtin.compactMap { item in
            let url = env.expand(item.path)
            guard FileKind.of(url) != nil else { return nil }
            let m = Measure.measure(url)
            return Candidate(rule: .bigItems, url: url, root: env.home, minDepth: 2, bytes: m.bytes,
                             lastActivity: m.latest, verdict: .keep(reason: item.note))
        }
    }
}
