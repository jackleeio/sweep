import XCTest
@testable import SweepCore

final class PathGuardTests: XCTestCase {
    func testAcceptsPathInsideRoot() {
        let h = TempHome()
        let target = h.dir("root/a/cache")
        XCTAssertNil(PathGuard.validate(target, root: h.path("root")))
    }

    func testRejectsTheRootItself() {
        let h = TempHome()
        let root = h.dir("root")
        XCTAssertEqual(PathGuard.validate(root, root: root), .isRoot)
    }

    func testRejectsPathOutsideRoot() {
        let h = TempHome()
        h.dir("root")
        let outside = h.dir("elsewhere/cache")
        XCTAssertEqual(PathGuard.validate(outside, root: h.path("root")), .outsideRoot)
    }

    func testRejectsSiblingWithSharedNamePrefix() {
        let h = TempHome()
        h.dir("root")
        let sibling = h.dir("root-other/cache")
        XCTAssertEqual(PathGuard.validate(sibling, root: h.path("root")), .outsideRoot)
    }

    func testRejectsSymlinkCandidate() throws {
        let h = TempHome()
        h.dir("root")
        let real = h.dir("elsewhere/precious")
        let link = h.path("root/cache")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertEqual(PathGuard.validate(link, root: h.path("root")), .symlink)
    }

    func testRejectsPathReachedThroughSymlinkedParent() throws {
        let h = TempHome()
        h.dir("root")
        h.dir("elsewhere/proj/cache")
        try FileManager.default.createSymbolicLink(at: h.path("root/proj"), withDestinationURL: h.path("elsewhere/proj"))
        XCTAssertEqual(PathGuard.validate(h.path("root/proj/cache"), root: h.path("root")), .outsideRoot)
    }

    func testRejectsForbiddenComponent() {
        let h = TempHome()
        let target = h.dir("root/proj/memory/notes")
        XCTAssertEqual(PathGuard.validate(target, root: h.path("root")), .forbiddenComponent("memory"))
    }

    func testRejectsPathShallowerThanMinDepth() {
        let h = TempHome()
        let target = h.dir("root/Library")
        XCTAssertEqual(PathGuard.validate(target, root: h.path("root"), minDepth: 2), .tooShallow)
    }

    func testRejectsMissingPath() {
        let h = TempHome()
        h.dir("root")
        XCTAssertEqual(PathGuard.validate(h.path("root/nope"), root: h.path("root")), .missing)
    }
}

final class MeasureTests: XCTestCase {
    func testSumsAllocatedBytesOfTree() {
        let h = TempHome()
        h.file("d/a.bin", bytes: 100_000)
        h.file("d/sub/b.bin", bytes: 200_000)
        let m = Measure.measure(h.path("d"))
        XCTAssertGreaterThanOrEqual(m.bytes, 300_000)
        XCTAssertLessThan(m.bytes, 400_000)
    }

    func testLatestIsNewestModificationInTree() {
        let h = TempHome()
        h.file("d/old.bin")
        h.file("d/sub/new.bin")
        h.age("d", daysAgo: 10)
        h.age("d/sub/new.bin", daysAgo: 1)
        let m = Measure.measure(h.path("d"))
        let age = h.now.timeIntervalSince(m.latest!) / 86400
        XCTAssertEqual(age, 1, accuracy: 0.01)
    }

    func testMeasuresSingleFile() {
        let h = TempHome()
        h.file("f.bin", bytes: 50_000)
        XCTAssertGreaterThanOrEqual(Measure.measure(h.path("f.bin")).bytes, 50_000)
    }

    func testDoesNotFollowSymlinkOutOfTree() throws {
        let h = TempHome()
        h.file("big/huge.bin", bytes: 500_000)
        h.file("d/small.bin", bytes: 1_000)
        try FileManager.default.createSymbolicLink(at: h.path("d/link"), withDestinationURL: h.path("big"))
        XCTAssertLessThan(Measure.measure(h.path("d")).bytes, 100_000)
    }
}

final class TokenScannerTests: XCTestCase {
    let token = "sweep-pin:v1:0f8fad5b-d9cb-469f-a165-70867728950e"

    func testFindsTokenInFile() {
        let h = TempHome()
        let f = h.file("s.jsonl", text: "{\"out\":\"已标记 \(token)\"}\n")
        XCTAssertEqual(TokenScanner.tokens(in: f), [token])
    }

    func testFindsTokenSpanningChunkBoundary() {
        let h = TempHome()
        let f = h.file("s.jsonl", text: String(repeating: "x", count: 50) + token + String(repeating: "y", count: 50))
        XCTAssertEqual(TokenScanner.tokens(in: f, chunkSize: 64), [token])
    }

    func testIgnoresMalformedToken() {
        let h = TempHome()
        let f = h.file("s.jsonl", text: "sweep-pin:v1:not-a-uuid-at-all-not-a-uuid-at-all-xx")
        XCTAssertEqual(TokenScanner.tokens(in: f), [])
    }

    func testEmptyForMissingFile() {
        let h = TempHome()
        XCTAssertEqual(TokenScanner.tokens(in: h.path("nope.jsonl")), [])
    }
}

final class PinStoreTests: XCTestCase {
    func testAddGeneratesDistinctPrefixedTokens() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        let a = try store.add(label: "a", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        let b = try store.add(label: "b", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        XCTAssertTrue(a.token.hasPrefix(TokenScanner.prefix))
        XCTAssertNotEqual(a.token, b.token)
    }

    func testPersistsAcrossInstances() throws {
        let h = TempHome()
        let pin = try PinStore(file: h.path("pins.json")).add(label: "重要", sessionID: "abc", agent: "claude", cwd: "/x", now: h.now)
        XCTAssertEqual(try PinStore(file: h.path("pins.json")).all(), [pin])
    }

    func testRemoveByLabel() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        try store.add(label: "a", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        let b = try store.add(label: "b", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        XCTAssertEqual(try store.remove(matching: "a").count, 1)
        XCTAssertEqual(try store.all(), [b])
    }

    func testRemoveByToken() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        let a = try store.add(label: "a", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        XCTAssertEqual(try store.remove(matching: a.token).count, 1)
        XCTAssertEqual(try store.all(), [])
    }

    func testMatchesBySessionID() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        let pin = try store.add(label: "a", sessionID: "sess-1", agent: nil, cwd: nil, now: h.now)
        let f = h.file("sess-1.jsonl", text: "no token here")
        XCTAssertEqual(try store.match(file: f, sessionID: "sess-1"), pin)
        XCTAssertNil(try store.match(file: f, sessionID: "sess-2"))
    }

    func testMatchesByTokenInsideFile() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        let pin = try store.add(label: "a", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        let f = h.file("rollout.jsonl", text: "{\"output\":\"\(pin.token)\"}")
        XCTAssertEqual(try store.match(file: f, sessionID: nil), pin)
    }

    func testUnregisteredTokenInFileDoesNotMatch() throws {
        let h = TempHome()
        let store = PinStore(file: h.path("pins.json"))
        try store.add(label: "a", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        let f = h.file("rollout.jsonl", text: "sweep-pin:v1:0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertNil(try store.match(file: f, sessionID: nil))
    }
}

extension PinStoreTests {
    func testCorruptPinsFileThrowsInsteadOfReadingAsEmpty() {
        let h = TempHome()
        let f = h.file("pins.json", text: "[ broken")
        XCTAssertThrowsError(try PinStore(file: f).all())
    }
}

final class ConfigTests: XCTestCase {
    func testMissingFileYieldsApprovedDefaults() throws {
        let h = TempHome()
        let c = try Config.load(from: h.path("config.json"))
        XCTAssertEqual(c.idleDays, 3)
        XCTAssertEqual(c.projectRoots, ["~/Projects"])
        XCTAssertTrue(c.buildCaches.enabled)
        XCTAssertEqual(c.buildCaches.sizeCapGB, 10)
        XCTAssertTrue(c.conversations.enabled)
        XCTAssertTrue(c.packageCaches.enabled)
        XCTAssertEqual(c.packageCaches.totalCapGB, 20)
        XCTAssertFalse(c.artifacts.enabled)
        XCTAssertEqual(c.artifacts.idleDays, 30)
    }

    func testPartialFileKeepsDefaultsForMissingKeys() throws {
        let h = TempHome()
        let f = h.file("config.json", text: #"{"idleDays": 7, "conversations": {"enabled": false}}"#)
        let c = try Config.load(from: f)
        XCTAssertEqual(c.idleDays, 7)
        XCTAssertFalse(c.conversations.enabled)
        XCTAssertEqual(c.conversations.claudeRoots, Config().conversations.claudeRoots)
        XCTAssertEqual(c.buildCaches.sizeCapGB, 10)
    }

    func testCorruptFileThrowsInsteadOfFallingBackToDefaults() {
        let h = TempHome()
        let f = h.file("config.json", text: "{ not json")
        XCTAssertThrowsError(try Config.load(from: f))
    }

    func testRoundTrip() throws {
        let h = TempHome()
        var c = Config()
        c.idleDays = 5
        c.artifacts.enabled = true
        try c.save(to: h.path("sub/config.json"))
        XCTAssertEqual(try Config.load(from: h.path("sub/config.json")), c)
    }

    func testPackageCachesNeverIncludeNpxDirectory() {
        XCTAssertFalse(Config().packageCaches.paths.contains { $0.contains("_npx") })
    }
}
