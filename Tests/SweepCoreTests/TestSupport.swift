import Foundation
import XCTest
@testable import SweepCore

/// 一个隔离的假 home 目录，测试结束自动删除。
final class TempHome {
    let url: URL
    let now = Date()
    private let fm = FileManager.default

    init() {
        let base = fm.temporaryDirectory.appendingPathComponent("sweep-tests-\(UUID().uuidString)")
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        // 用 realpath 后的路径，避免 /var 与 /private/var 不一致
        let resolved = realpath(base.path, nil)!
        url = URL(fileURLWithPath: String(cString: resolved))
        free(resolved)
    }

    deinit { try? fm.removeItem(at: url) }

    func path(_ rel: String) -> URL { url.appendingPathComponent(rel) }

    @discardableResult
    func dir(_ rel: String) -> URL {
        let u = path(rel)
        try! fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @discardableResult
    func file(_ rel: String, bytes: Int = 16, text: String? = nil) -> URL {
        let u = path(rel)
        try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = text.map { Data($0.utf8) } ?? Data(repeating: 0x61, count: bytes)
        try! data.write(to: u)
        return u
    }

    /// 把 rel 及其下所有内容的修改时间设为 daysAgo 天前。
    func age(_ rel: String, daysAgo: Double) {
        let root = path(rel)
        let date = now.addingTimeInterval(-daysAgo * 86400)
        var all = [root]
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let u as URL in e { all.append(u) }
        }
        for u in all {
            try! fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
        }
    }

    func exists(_ rel: String) -> Bool { fm.fileExists(atPath: path(rel).path) }

    func env(inUse: @escaping (URL, CacheKind) -> Bool = { _, _ in false }, free: @escaping () -> Int64 = { .max }) -> Env {
        Env(home: url, now: now, processProbe: FakeProbe(inUse), freeBytes: free)
    }

    func git(_ args: String..., in rel: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", path(rel).path, "-c", "user.name=t", "-c", "user.email=t@t"] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(args) failed")
    }
}

struct FakeProbe: ProcessProbe {
    let fn: (URL, CacheKind) -> Bool
    init(_ fn: @escaping (URL, CacheKind) -> Bool) { self.fn = fn }
    func isInUse(projectDir: URL, kind: CacheKind) -> Bool { fn(projectDir, kind) }
}

extension Array where Element == Candidate {
    func named(_ suffix: String) -> Candidate? { first { $0.url.path.hasSuffix(suffix) } }
    var deletable: [Candidate] { filter { $0.isDelete } }
}

extension TempHome {
    func sqlite(_ rel: String, _ sql: String) {
        try! FileManager.default.createDirectory(at: path(rel).deletingLastPathComponent(), withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path(rel).path, sql]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try! p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
}

/// 在假 home 里搭一个 Codex 目录：会话文件、状态数据库、全局状态文件。
struct CodexFixture {
    let h: TempHome

    static func id(_ n: Int) -> String { String(format: "01a130dd-f6c0-71a0-8d0b-%012d", n) }

    init(_ h: TempHome, database: Bool = true) {
        self.h = h
        guard database else { return }
        h.sqlite(".codex/state_5.sqlite", """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, title TEXT NOT NULL DEFAULT '', name TEXT,
          archived INTEGER NOT NULL DEFAULT 0, thread_section_id TEXT, agent_role TEXT, agent_path TEXT,
          updated_at_ms INTEGER, cwd TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '');
        CREATE TABLE thread_sections (id TEXT PRIMARY KEY, name TEXT, appearance TEXT);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT, status TEXT);
        INSERT INTO thread_sections VALUES ('sec-pinned', 'Pinned', NULL);
        """)
    }

    /// 建一个会话文件并（默认）在数据库里登记。返回相对 home 的路径。
    @discardableResult
    func session(_ n: Int, daysAgo: Double, archived: Bool = false, pinnedSection: Bool = false, cwd: String = "/work",
                 inDatabase: Bool = true, role: String? = nil, databaseDaysAgo: Double? = nil,
                 directory: String = "sessions/2026/09/01", title: String = "对话", compressed: Bool = false) -> String {
        let id = Self.id(n)
        // Codex 会把旧会话压缩成 .jsonl.zst，但数据库里登记的路径仍是 .jsonl
        let recorded = ".codex/\(directory)/rollout-2026-09-01T00-00-00-\(id).jsonl"
        let rel = compressed ? recorded + ".zst" : recorded
        h.file(rel, bytes: 10_000)
        h.age(rel, daysAgo: daysAgo)
        if inDatabase {
            let updated = Int((h.now.timeIntervalSince1970 - (databaseDaysAgo ?? daysAgo) * 86400) * 1000)
            let section = pinnedSection ? "'sec-pinned'" : "NULL"
            let agentRole = role.map { "'\($0)'" } ?? "NULL"
            h.sqlite(".codex/state_5.sqlite", """
            INSERT INTO threads (id, rollout_path, title, archived, thread_section_id, agent_role, updated_at_ms, cwd)
            VALUES ('\(id)', '\(h.path(recorded).path)', '\(title) \(n)', \(archived ? 1 : 0), \(section), \(agentRole), \(updated), '\(cwd)');
            """)
        }
        return rel
    }

    func spawn(parent: Int, child: Int) {
        h.sqlite(".codex/state_5.sqlite",
                 "INSERT INTO thread_spawn_edges VALUES ('\(Self.id(parent))', '\(Self.id(child))', 'done');")
    }

    func state(pinned: [Int] = [], pinnedProjects: [String] = [], projects: [String: [String]] = [:],
               assignments: [Int: String] = [:], sidebar: [String: [Int]] = [:]) {
        let json: [String: Any] = [
            "pinned-thread-ids": pinned.map(Self.id),
            "pinned-project-ids": pinnedProjects,
            "local-projects": projects.mapValues { ["rootPaths": $0] },
            "thread-project-assignments": Dictionary(uniqueKeysWithValues: assignments.map { (Self.id($0.key), ["projectKind": "local", "projectId": $0.value]) }),
            "sidebar-project-thread-orders": sidebar.mapValues { ["threadIds": $0.map(Self.id)] },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! FileManager.default.createDirectory(at: h.path(".codex"), withIntermediateDirectories: true)
        try! data.write(to: h.path(".codex/.codex-global-state.json"))
    }
}
