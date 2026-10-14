import Foundation

private extension KeyedDecodingContainer {
    /// 缺失的键取默认值，便于以后加配置项时兼容旧文件。
    func value<T: Decodable>(_ key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

/// 用户配置。
///
/// 各规则要扫描的路径分两部分：内置列表写在代码里（`builtin…`），配置文件只保存用户额外
/// 添加的（`extra…`）。这样升级时新增的内置路径不会被旧配置文件里的列表盖住。
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

    /// 闲置项目里可以重新安装的依赖目录：node_modules 和虚拟环境。
    public struct Dependencies: Codable, Equatable {
        public var enabled = true
        /// 项目多少天没有改动才清它的依赖。
        public var idleDays: Double = 14
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Dependencies()
            enabled = try c.value(.enabled, default: d.enabled)
            idleDays = try c.value(.idleDays, default: d.idleDays)
        }
    }

    public struct AgentTemp: Codable, Equatable {
        public static let builtinGlobs = ["~/.cache/bnbot-*", "~/Library/Caches/bnbot-*"]
        public var enabled = true
        public var extraGlobs: [String] = []
        public var globs: [String] { Self.builtinGlobs + extraGlobs }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: true)
            extraGlobs = try c.value(.extraGlobs, default: [])
        }
    }

    /// Codex 的对话。
    public struct Conversations: Codable, Equatable {
        public static let builtinCodexRoots = ["~/.codex/sessions", "~/.codex/archived_sessions"]
        public var enabled = true
        /// 多少天没更新就删除。归档过的对话不看这个值，安静 3 天即删。
        public var idleDays: Double = 7
        public var extraCodexRoots: [String] = []
        public var codexRoots: [String] { Self.builtinCodexRoots + extraCodexRoots }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: true)
            idleDays = try c.value(.idleDays, default: 7)
            extraCodexRoots = try c.value(.extraCodexRoots, default: [])
        }
    }

    /// Claude Code 的对话。
    public struct ClaudeConversations: Codable, Equatable {
        public static let builtinClaudeRoots = ["~/.claude/projects"]
        public var enabled = true
        public var idleDays: Double = 7
        public var extraClaudeRoots: [String] = []
        public var claudeRoots: [String] { Self.builtinClaudeRoots + extraClaudeRoots }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: true)
            idleDays = try c.value(.idleDays, default: 7)
            extraClaudeRoots = try c.value(.extraClaudeRoots, default: [])
        }
    }

    /// 语音输入工具留下的历史录音。
    public struct Recordings: Codable, Equatable {
        public static let builtinPaths = ["~/Library/Application Support/Shandianshuo/workspace/history/recordings"]
        public var enabled = true
        public var idleDays: Double = 7
        public var extraPaths: [String] = []
        public var paths: [String] { Self.builtinPaths + extraPaths }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: true)
            idleDays = try c.value(.idleDays, default: 7)
            extraPaths = try c.value(.extraPaths, default: [])
        }
    }

    /// 包管理器和开发工具的下载缓存，删掉后会在需要时自动重新下载。
    public struct PackageCaches: Codable, Equatable {
        // 注意：~/.npm/_npx 里是 npx 装的包（可能带本地补丁），不属于缓存，不能列进来
        public static let builtinPaths = [
            "~/Library/Caches/Yarn",
            "~/.npm/_cacache",
            "~/.cache/uv",
            "~/Library/Caches/pip",
            "~/Library/pnpm/store",
            "~/Library/Caches/pnpm",
            "~/.bun/install/cache",
            "~/.yarn/berry/cache",
            "~/.docker/scout",
        ]
        public var enabled = true
        /// 所列缓存合计超过这个体积才清理。
        public var totalCapGB: Double = 20
        public var extraPaths: [String] = []
        public var paths: [String] { Self.builtinPaths + extraPaths }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PackageCaches()
            enabled = try c.value(.enabled, default: d.enabled)
            totalCapGB = try c.value(.totalCapGB, default: d.totalCapGB)
            extraPaths = try c.value(.extraPaths, default: [])
        }
    }

    /// ~/Library/Caches 下其他应用的缓存。
    public struct AppCaches: Codable, Equatable {
        public static let builtinRoots = ["~/Library/Caches"]
        /// 名字以这些开头的不碰：系统缓存，以及名义上是缓存、实际是装好的浏览器内核的目录（删了不会自动恢复）
        public static let builtinSkipPrefixes = ["com.apple.", "ms-playwright", "Cypress"]
        /// 名字里含这些词的视为 AI 工具或 agent 的缓存（不区分大小写）。
        public static let aiToolKeywords = [
            "openai", "chatgpt", "codex", "claude", "anthropic", "bnbot", "clawmoney", "spareai", "manus", "trae",
            "windsurf", "exafunction", "cursor", "todesktop.230313mzl4w4u92", "mmx-agent", "matrix", "gemini", "goose",
            "opencode", "kimi", "bloop", "codewhisperer", "ccswitch", "superwhisper", "wispr", "dayflow", "comet",
            "doubao", "copilot", "perplexity", "ollama", "lmstudio", "huggingface", "qoder", "grok", "minimax",
            "deepseek", "zoe-desktop", "neo-cli", "beads", "com.meta.endo", "conversationcache",
        ]
        public var enabled = true
        /// 保留 AI 工具和 agent 的缓存，只清其他应用的。
        public var keepAITools = true
        public var extraSkipPrefixes: [String] = []
        public var roots: [String] { Self.builtinRoots }
        public var skipPrefixes: [String] { Self.builtinSkipPrefixes + extraSkipPrefixes }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: true)
            keepAITools = try c.value(.keepAITools, default: true)
            extraSkipPrefixes = try c.value(.extraSkipPrefixes, default: [])
        }
    }

    public struct Artifacts: Codable, Equatable {
        public static let builtinPaths = ["~/.codex/visualizations", "~/.codex/generated_images"]
        public var enabled = false
        public var idleDays: Double = 30
        public var extraPaths: [String] = []
        public var paths: [String] { Self.builtinPaths + extraPaths }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Artifacts()
            enabled = try c.value(.enabled, default: d.enabled)
            idleDays = try c.value(.idleDays, default: d.idleDays)
            extraPaths = try c.value(.extraPaths, default: [])
        }
    }

    /// worktree 和构建副本。默认只展示；打开后，干净且闲置的 git 工作树会被移除（分支保留）。
    public struct WorkCopies: Codable, Equatable {
        public static let builtinGlobs = ["~/Projects/*-worktrees/*", "~/Projects/*-build*", "~/.codex/worktrees/*/*"]
        public var enabled = false
        public var idleDays: Double = 14
        public var extraGlobs: [String] = []
        public var globs: [String] { Self.builtinGlobs + extraGlobs }
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.value(.enabled, default: false)
            idleDays = try c.value(.idleDays, default: 14)
            extraGlobs = try c.value(.extraGlobs, default: [])
        }
    }

    /// 体积大、但不能靠删文件来清理的东西。只在界面上列出，提醒它们的存在。
    public enum BigItems {
        public static let builtin: [(path: String, note: String)] = [
            ("~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker 的虚拟磁盘。要在 Docker 里清理悬空镜像和构建缓存，直接删会丢掉容器和数据卷"),
            ("~/Library/Application Support/Claude/vm_bundles", "Claude 桌面版本地 agent 模式的虚拟机镜像。不用这个功能可以手动删，下次使用会重新下载"),
            ("~/.codex/thread_history_1.sqlite", "Codex 的对话内容索引。由 Codex 自己维护，不能手工删"),
            ("~/Library/Application Support/BNBot/CodexAppServer/logs_2.sqlite", "BNBot 内嵌 Codex 的调试日志。退出 BNBot 后可以删，会自动重建"),
        ]
    }

    /// 多少天没有更新即视为不再使用。
    public var idleDays: Double = 3
    /// 可用空间低于这个值时立即清理，不等每日任务。0 表示关闭。
    public var lowSpaceGB: Double = 100
    /// 每日清理后可用空间仍低于这个值时，改用收紧的规则再清一遍。0 表示关闭。
    public var targetFreeGB: Double = 300
    /// 每日例行清理在几点之后进行（0–23）。
    public var dailyHour = 3
    /// 任何规则都不会碰的路径。
    public var excludes: [String] = []
    public var projectRoots = ["~/Projects"]
    public var buildCaches = BuildCaches()
    public var dependencies = Dependencies()
    public var agentTemp = AgentTemp()
    public var conversations = Conversations()
    public var claudeConversations = ClaudeConversations()
    public var recordings = Recordings()
    public var packageCaches = PackageCaches()
    public var appCaches = AppCaches()
    public var artifacts = Artifacts()
    public var workCopies = WorkCopies()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        idleDays = try c.value(.idleDays, default: d.idleDays)
        lowSpaceGB = try c.value(.lowSpaceGB, default: d.lowSpaceGB)
        targetFreeGB = try c.value(.targetFreeGB, default: d.targetFreeGB)
        dailyHour = try c.value(.dailyHour, default: d.dailyHour)
        excludes = try c.value(.excludes, default: d.excludes)
        projectRoots = try c.value(.projectRoots, default: d.projectRoots)
        buildCaches = try c.value(.buildCaches, default: d.buildCaches)
        dependencies = try c.value(.dependencies, default: d.dependencies)
        agentTemp = try c.value(.agentTemp, default: d.agentTemp)
        conversations = try c.value(.conversations, default: d.conversations)
        claudeConversations = try c.value(.claudeConversations, default: d.claudeConversations)
        recordings = try c.value(.recordings, default: d.recordings)
        packageCaches = try c.value(.packageCaches, default: d.packageCaches)
        appCaches = try c.value(.appCaches, default: d.appCaches)
        artifacts = try c.value(.artifacts, default: d.artifacts)
        workCopies = try c.value(.workCopies, default: d.workCopies)
    }

    /// 这条规则现在会不会真的清理东西。
    public func isEnabled(_ rule: RuleID) -> Bool {
        switch rule {
        case .buildCaches: return buildCaches.enabled
        case .dependencies: return dependencies.enabled
        case .workCopies: return workCopies.enabled
        case .agentTemp: return agentTemp.enabled
        case .conversations: return conversations.enabled
        case .claudeConversations: return claudeConversations.enabled
        case .packageCaches: return packageCaches.enabled
        case .appCaches: return appCaches.enabled
        case .artifacts: return artifacts.enabled
        case .recordings: return recordings.enabled
        case .bigItems: return false
        }
    }

    /// 有开关、且目前关着的规则。
    public var disabledRules: Set<RuleID> {
        Set(RuleID.allCases.filter { $0 != .bigItems && !isEnabled($0) })
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
