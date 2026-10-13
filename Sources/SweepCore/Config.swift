import Foundation

private extension KeyedDecodingContainer {
    /// 缺失的键取默认值，便于以后加配置项时兼容旧文件。
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

public struct Config: Codable, Equatable {
    public struct BuildCaches: Codable, Equatable {
        public var enabled = true
        /// 单个缓存超过这个体积时，即使最近在用也清理。
        public var sizeCapGB: Double = 10
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = BuildCaches()
            enabled = try c.value(.enabled, default: d.enabled)
            sizeCapGB = try c.value(.sizeCapGB, default: d.sizeCapGB)
        }
    }

    public struct AgentTemp: Codable, Equatable {
        public var enabled = true
        public var globs = ["~/.cache/bnbot-*", "~/Library/Caches/bnbot-*"]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = AgentTemp()
            enabled = try c.value(.enabled, default: d.enabled)
            globs = try c.value(.globs, default: d.globs)
        }
    }

    public struct Conversations: Codable, Equatable {
        public var enabled = true
        public var codexRoots = ["~/.codex/sessions", "~/.codex/archived_sessions"]
        public var claudeRoots = ["~/.claude/projects"]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Conversations()
            enabled = try c.value(.enabled, default: d.enabled)
            codexRoots = try c.value(.codexRoots, default: d.codexRoots)
            claudeRoots = try c.value(.claudeRoots, default: d.claudeRoots)
        }
    }

    public struct PackageCaches: Codable, Equatable {
        public var enabled = true
        /// 所列缓存合计超过这个体积才清理。
        public var totalCapGB: Double = 20
        // 注意：~/.npm/_npx 里是 npx 装的包（可能带本地补丁），不属于缓存，不能列进来
        public var paths = [
            "~/Library/Caches/Yarn",
            "~/.npm/_cacache",
            "~/.cache/uv",
            "~/Library/Caches/pip",
            "~/Library/pnpm/store",
        ]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PackageCaches()
            enabled = try c.value(.enabled, default: d.enabled)
            totalCapGB = try c.value(.totalCapGB, default: d.totalCapGB)
            paths = try c.value(.paths, default: d.paths)
        }
    }

    public struct Artifacts: Codable, Equatable {
        public var enabled = false
        public var idleDays: Double = 30
        public var paths = ["~/.codex/visualizations", "~/.codex/generated_images"]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Artifacts()
            enabled = try c.value(.enabled, default: d.enabled)
            idleDays = try c.value(.idleDays, default: d.idleDays)
            paths = try c.value(.paths, default: d.paths)
        }
    }

    /// 只展示体积，永不自动删除。
    public struct WorkCopies: Codable, Equatable {
        public var globs = ["~/Projects/*-worktrees/*", "~/Projects/*-build*"]
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            globs = try c.value(.globs, default: WorkCopies().globs)
        }
    }

    /// 多少天没有更新即视为不再使用。
    public var idleDays: Double = 3
    public var projectRoots = ["~/Projects"]
    public var buildCaches = BuildCaches()
    public var agentTemp = AgentTemp()
    public var conversations = Conversations()
    public var packageCaches = PackageCaches()
    public var artifacts = Artifacts()
    public var workCopies = WorkCopies()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        idleDays = try c.value(.idleDays, default: d.idleDays)
        projectRoots = try c.value(.projectRoots, default: d.projectRoots)
        buildCaches = try c.value(.buildCaches, default: d.buildCaches)
        agentTemp = try c.value(.agentTemp, default: d.agentTemp)
        conversations = try c.value(.conversations, default: d.conversations)
        packageCaches = try c.value(.packageCaches, default: d.packageCaches)
        artifacts = try c.value(.artifacts, default: d.artifacts)
        workCopies = try c.value(.workCopies, default: d.workCopies)
    }

    /// 文件不存在时用默认值；存在但损坏时抛错，不回退到默认值，
    /// 以免用户关掉的规则被悄悄重新打开。
    public static func load(from url: URL) throws -> Config {
        try JSONFiles.read(Config.self, from: url) ?? Config()
    }

    public func save(to url: URL) throws {
        try JSONFiles.write(self, to: url)
    }
}
