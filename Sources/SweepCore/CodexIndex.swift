import Foundation
import SQLite3

/// Codex 自己记录的对话状态：哪些被置顶、归档，哪些是子 agent 的会话。
/// 只读。数据来自 `state_5.sqlite` 和 `.codex-global-state.json`。
public struct CodexIndex {
    public struct Thread {
        public var id: String
        public var rolloutPath: String
        public var archived: Bool
        public var inPinnedSection: Bool
        public var isSubagent: Bool
        public var cwd: String
        public var updatedAt: Date?
    }

    public enum LoadError: Error {
        case database(String)
        case globalState
    }

    public private(set) var byPath: [String: Thread] = [:]
    public private(set) var byID: [String: Thread] = [:]
    public private(set) var parentOf: [String: String] = [:]
    public private(set) var pinnedThreadIDs: Set<String> = []
    /// 明确归到置顶项目里的对话（按分配记录或侧栏顺序）。
    public private(set) var threadsInPinnedProjects: Set<String> = []
    /// 置顶项目的根目录；工作目录在其中的对话也算在项目里。
    public private(set) var pinnedProjectRoots: [String] = []
    /// 数据库存在并且读出来了。为 false 时无从判断「Codex 里有没有这条记录」。
    public private(set) var hasDatabase = false

    /// 两个文件都不存在时返回空索引；存在但读不懂时抛错，调用方此时不应删除任何 Codex 对话。
    public static func load(codexHome: URL) throws -> CodexIndex {
        var index = CodexIndex()
        try index.loadGlobalState(codexHome.appendingPathComponent(".codex-global-state.json"))
        try index.loadDatabase(codexHome.appendingPathComponent("state_5.sqlite"))
        return index
    }

    public func isPinned(_ id: String) -> Bool {
        pinnedThreadIDs.contains(id) || byID[id]?.inPinnedSection == true
    }

    public func isInPinnedProject(_ id: String) -> Bool {
        if threadsInPinnedProjects.contains(id) { return true }
        guard let cwd = byID[id]?.cwd, !cwd.isEmpty else { return false }
        return pinnedProjectRoots.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
    }

    /// 沿着「谁派生了谁」一路找到最初的那条对话。
    public func rootConversation(of id: String) -> String? {
        var current = id
        var seen: Set<String> = [id]
        while let parent = parentOf[current] {
            guard seen.insert(parent).inserted else { return nil }
            current = parent
        }
        return current == id ? nil : current
    }

    // MARK: - 全局状态文件

    private mutating func loadGlobalState(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LoadError.globalState }

        pinnedThreadIDs = Set(state["pinned-thread-ids"] as? [String] ?? [])
        let pinnedProjects = Set(state["pinned-project-ids"] as? [String] ?? [])
        guard !pinnedProjects.isEmpty else { return }

        let projects = state["local-projects"] as? [String: [String: Any]] ?? [:]
        pinnedProjectRoots = pinnedProjects.flatMap { projects[$0]?["rootPaths"] as? [String] ?? [] }

        let assignments = state["thread-project-assignments"] as? [String: [String: Any]] ?? [:]
        for (thread, assignment) in assignments {
            if let project = assignment["projectId"] as? String, pinnedProjects.contains(project) {
                threadsInPinnedProjects.insert(thread)
            }
        }
        let orders = state["sidebar-project-thread-orders"] as? [String: [String: Any]] ?? [:]
        for project in pinnedProjects {
            threadsInPinnedProjects.formUnion(orders[project]?["threadIds"] as? [String] ?? [])
        }
    }

    // MARK: - 状态数据库

    private mutating func loadDatabase(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw LoadError.database("打不开")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // 不同版本的 Codex 列不完全一样：必需的列缺了就报错，可选的列缺了当作空
        let columns = Set(try Self.rows(db, "PRAGMA table_info(threads)").compactMap { $0.count > 1 ? $0[1] : nil })
        guard columns.contains("id"), columns.contains("rollout_path") else { throw LoadError.database("threads 表结构不认识") }
        func column(_ name: String) -> String { columns.contains(name) ? name : "NULL" }

        let sectionRows = (try? Self.rows(db, "SELECT id FROM thread_sections WHERE name = 'Pinned'")) ?? []
        let pinnedSections = Set(sectionRows.compactMap { $0.first ?? nil })
        var subagents: Set<String> = []
        for edge in (try? Self.rows(db, "SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges")) ?? [] {
            guard let parent = edge[0], let child = edge[1] else { continue }
            parentOf[child] = parent
            subagents.insert(child)
        }

        let sql = "SELECT id, rollout_path, \(column("archived")), \(column("thread_section_id")), \(column("agent_role")), "
            + "\(column("agent_path")), \(column("updated_at_ms")), \(column("cwd")), \(column("source")) FROM threads"
        for row in try Self.rows(db, sql) {
            guard let id = row[0], let path = row[1], !path.isEmpty else { continue }
            let spawned = !(row[4] ?? "").isEmpty || !(row[5] ?? "").isEmpty || (row[8] ?? "").contains("subagent")
            let thread = Thread(id: id, rolloutPath: path, archived: row[2] == "1",
                                inPinnedSection: row[3].map { pinnedSections.contains($0) } ?? false,
                                isSubagent: subagents.contains(id) || spawned, cwd: row[7] ?? "",
                                updatedAt: row[6].flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) })
            byPath[path] = thread
            byID[id] = thread
        }
        hasDatabase = true
    }

    /// 执行查询，每个单元格以文本返回（NULL 为 nil）。
    private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw LoadError.database(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        let count = sqlite3_column_count(stmt)
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw LoadError.database(String(cString: sqlite3_errmsg(db))) }
            out.append((0..<count).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } })
        }
        return out
    }
}
