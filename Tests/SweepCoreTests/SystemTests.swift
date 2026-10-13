import XCTest
@testable import SweepCore

final class LiveProcessProbeTests: XCTestCase {
    private func matches(_ command: String, cwd: String, project: String = "/p/app", kind: CacheKind = .next) -> Bool {
        LiveProcessProbe.matches(command: command, cwd: cwd, projectDir: project, kind: kind)
    }

    func testNextDevServerInsideProjectCountsAsInUse() {
        XCTAssertTrue(matches("node /p/app/node_modules/.bin/next dev -p 3000", cwd: "/p/app"))
    }

    func testNextServerProcessTitleCounts() {
        XCTAssertTrue(matches("next-server (v16.2.4)", cwd: "/p/app"))
    }

    func testProcessInSubdirectoryOfProjectCounts() {
        XCTAssertTrue(matches("next-server (v16.2.4)", cwd: "/p/app/apps/web"))
    }

    func testUnrelatedProcessInsideProjectDoesNotCount() {
        XCTAssertFalse(matches("/Users/a/.local/bin/claude", cwd: "/p/app"))
        XCTAssertFalse(matches("node /x/chrome-devtools-mcp/index.js", cwd: "/p/app"))
    }

    func testDevServerOfSiblingProjectDoesNotCount() {
        XCTAssertFalse(matches("next-server (v16.2.4)", cwd: "/p/app2"))
    }

    func testPathComparisonIgnoresCase() {
        XCTAssertTrue(matches("next-server (v16.2.4)", cwd: "/Users/a/projects/app", project: "/Users/a/Projects/app"))
    }

    func testCargoCountsOnlyForTauriTarget() {
        XCTAssertTrue(matches("cargo build --release", cwd: "/p/app/src-tauri", kind: .cargoTarget))
        XCTAssertFalse(matches("cargo build --release", cwd: "/p/app/src-tauri", kind: .next))
    }

    func testOnlyAnActiveBunBuildBlocksLeftoverCleanup() {
        XCTAssertFalse(matches("bun run dev", cwd: "/p/app", kind: .bunBuild))
        XCTAssertTrue(matches("bun build --compile ./cli.ts", cwd: "/p/app", kind: .bunBuild))
    }

    func testReadsWorkingDirectoryOfThisProcess() {
        let expected = realPath(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        XCTAssertEqual(LiveProcessProbe.workingDirectory(of: getpid()), expected)
    }

    func testProcessListIncludesThisProcess() {
        XCTAssertEqual(LiveProcessProbe.processList()?.contains { $0.pid == getpid() }, true)
    }

    func testDetectsARealProcessRunningInsideTheProject() throws {
        let h = TempHome()
        h.dir("Projects/app")
        h.dir("Projects/other")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/bin/bash")
        server.arguments = ["-c", "exec -a next-server sleep 20"]
        server.currentDirectoryURL = h.path("Projects/app")
        try server.run()
        defer { server.terminate() }
        usleep(400_000)

        XCTAssertTrue(LiveProcessProbe().isInUse(projectDir: h.path("Projects/app"), kind: .next))
        XCTAssertFalse(LiveProcessProbe().isInUse(projectDir: h.path("Projects/other"), kind: .next))
    }
}

final class DiskTests: XCTestCase {
    func testReportsPlausibleCapacityForHome() {
        let usage = Disk.usage(at: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertGreaterThan(usage.total, 1 << 30)
        XCTAssertGreaterThan(usage.free, 0)
        XCTAssertLessThanOrEqual(usage.free, usage.total)
    }
}

final class ReportTextTests: XCTestCase {
    private func item(_ rule: RuleID, _ path: String, _ bytes: Int64, _ verdict: Verdict, blocked: Bool = false) -> Candidate {
        Candidate(rule: rule, url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/"), bytes: bytes,
                  lastActivity: nil, verdict: verdict, blockedByProcess: blocked)
    }

    func testListsDeletableItemsUnderTheirRuleWithSizes() {
        let text = ReportText.scan([
            item(.buildCaches, "/p/app/.next", 2_000_000_000, .delete(reason: "9 天没更新")),
            item(.conversations, "/c/a.jsonl", 3 << 20, .delete(reason: "5 天没更新")),
        ])
        XCTAssertTrue(text.contains("构建缓存"))
        XCTAssertTrue(text.contains("/p/app/.next"))
        XCTAssertTrue(text.contains("2.0 GB"))
        XCTAssertTrue(text.contains("9 天没更新"))
        XCTAssertTrue(text.contains("Agent 对话"))
    }

    func testShowsWhyProtectedItemsAreKept() {
        let text = ReportText.scan([
            item(.conversations, "/c/pinned.jsonl", 1 << 20, .keep(reason: "已标记：重要方案")),
            item(.buildCaches, "/p/app/.next", 20 << 30, .keep(reason: "超过 10G 上限，但有进程正在使用"), blocked: true),
        ])
        XCTAssertTrue(text.contains("已标记：重要方案"))
        XCTAssertTrue(text.contains("有进程正在使用"))
    }

    func testDoesNotListOrdinaryFreshItemsOneByOne() {
        let text = ReportText.scan([item(.conversations, "/c/fresh.jsonl", 1 << 20, .keep(reason: "最近有更新"))])
        XCTAssertFalse(text.contains("/c/fresh.jsonl"))
    }

    func testTruncatesLongListsUnlessAskedForEverything() {
        let many = (0..<40).map { item(.conversations, "/c/s\($0).jsonl", Int64(1000 + $0), .delete(reason: "9 天没更新")) }
        XCTAssertFalse(ReportText.scan(many, limitPerRule: 10).contains("/c/s0.jsonl"))
        XCTAssertTrue(ReportText.scan(many, limitPerRule: nil).contains("/c/s0.jsonl"))
    }

    func testEndsWithGrandTotalOfDeletableBytes() {
        let text = ReportText.scan([
            item(.buildCaches, "/a", 1_000_000_000, .delete(reason: "x")),
            item(.agentTemp, "/b", 1_000_000_000, .delete(reason: "x")),
            item(.workCopies, "/c", 50 << 30, .keep(reason: "仅展示，不自动清理")),
        ])
        XCTAssertTrue(text.contains("合计可清理 2 项，2.0 GB"))
    }
}

final class ScanSummaryTests: XCTestCase {
    private func item(_ rule: RuleID, _ bytes: Int64, _ verdict: Verdict) -> Candidate {
        Candidate(rule: rule, url: URL(fileURLWithPath: "/x"), root: URL(fileURLWithPath: "/"), bytes: bytes,
                  lastActivity: nil, verdict: verdict)
    }

    func testSummarisesCountsAndBytesPerRule() {
        let summary = ScanSummary.make(from: [
            item(.buildCaches, 100, .delete(reason: "x")),
            item(.buildCaches, 50, .delete(reason: "x")),
            item(.buildCaches, 7, .keep(reason: "最近在用")),
            item(.workCopies, 900, .keep(reason: "仅展示")),
        ], date: Date())
        XCTAssertEqual(summary[.buildCaches]?.deletableCount, 2)
        XCTAssertEqual(summary[.buildCaches]?.deletableBytes, 150)
        XCTAssertEqual(summary[.buildCaches]?.keptCount, 1)
        XCTAssertEqual(summary[.buildCaches]?.keptBytes, 7)
        XCTAssertEqual(summary[.workCopies]?.keptBytes, 900)
        XCTAssertEqual(summary[.workCopies]?.deletableCount, 0)
        XCTAssertNil(summary[.conversations])
        XCTAssertEqual(summary.deletableBytes, 150)
        XCTAssertEqual(summary.deletableCount, 2)
    }

    func testRoundTripsThroughFile() throws {
        let h = TempHome()
        let summary = ScanSummary.make(from: [item(.conversations, 42, .delete(reason: "x"))], date: h.now.wholeSeconds)
        try summary.save(to: h.env().scanFile)
        XCTAssertEqual(ScanSummary.load(from: h.env().scanFile), summary)
    }

    func testMissingFileLoadsAsNil() {
        let h = TempHome()
        XCTAssertNil(ScanSummary.load(from: h.env().scanFile))
    }
}

final class FormatTests: XCTestCase {
    /// 与「系统设置 › 储存空间」一致，按 1000 进制。
    func testUsesDecimalUnitsLikeSystemSettings() {
        XCTAssertEqual(Format.bytes(994_660_000_000), "995 GB")
        XCTAssertEqual(Format.bytes(36_000_000_000), "36.0 GB")
        XCTAssertEqual(Format.bytes(1_500_000), "1.5 MB")
        XCTAssertEqual(Format.bytes(999), "999 B")
    }
}
