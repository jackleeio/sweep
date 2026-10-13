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

    func env(inUse: @escaping (URL, CacheKind) -> Bool = { _, _ in false }) -> Env {
        Env(home: url, now: now, processProbe: FakeProbe(inUse))
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
