import Foundation

public enum RuleID: String, Codable, CaseIterable {
    case buildCaches
    case dependencies
    case workCopies
    case agentTemp
    /// Codex 的对话。沿用最初的名字，配置文件里的键不用迁移。
    case conversations
    case claudeConversations
    case packageCaches
    case appCaches
    case artifacts
    case recordings
    /// 体积大但不能自动清理的东西，只展示。
    case bigItems
}

public enum Verdict: Equatable {
    case delete(reason: String)
    case keep(reason: String)
}

/// 删除成功后要做的收尾。
public enum PostDelete: Equatable {
    /// 目录是某个仓库的 git 工作树：删掉后清理主仓库里对它的登记。
    case pruneWorktrees(mainRepository: URL)
}

/// 扫描命中的一项。verdict 为 keep 的项只用于展示，永远不会被删除。
public struct Candidate: Equatable {
    public let rule: RuleID
    public let url: URL
    /// 与 url 同属一个会话、需要一并删除的路径（如 Claude 会话的同名目录）。
    public let extraURLs: [URL]
    /// 删除前用于校验的根目录：url 必须严格位于其内部。
    public let root: URL
    public let minDepth: Int
    public let bytes: Int64
    public let lastActivity: Date?
    public let verdict: Verdict
    /// 本该清理，但检测到有进程正在使用，因此保留。
    public let blockedByProcess: Bool
    /// 用于在界面上分组的短标签，如「30–90 天没更新」「已归档」。没有就按原因分组。
    public let category: String?
    public let postDelete: PostDelete?

    public init(rule: RuleID, url: URL, extraURLs: [URL] = [], root: URL, minDepth: Int = 1,
                bytes: Int64, lastActivity: Date?, verdict: Verdict, blockedByProcess: Bool = false,
                category: String? = nil, postDelete: PostDelete? = nil) {
        self.rule = rule
        self.url = url
        self.extraURLs = extraURLs
        self.root = root
        self.minDepth = minDepth
        self.bytes = bytes
        self.lastActivity = lastActivity
        self.verdict = verdict
        self.blockedByProcess = blockedByProcess
        self.category = category
        self.postDelete = postDelete
    }

    public var isDelete: Bool {
        if case .delete = verdict { return true }
        return false
    }

    public var reason: String {
        switch verdict {
        case .delete(let r), .keep(let r): return r
        }
    }
}
