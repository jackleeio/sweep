import XCTest
@testable import SweepCore

final class CleanerTests: XCTestCase {
    private func candidate(_ h: TempHome, _ rel: String, root: String, rule: RuleID = .buildCaches,
                           verdict: Verdict = .delete(reason: "测试"), extra: [String] = [], minDepth: Int = 1) -> Candidate {
        let url = h.path(rel)
        return Candidate(rule: rule, url: url, extraURLs: extra.map(h.path), root: h.path(root), minDepth: minDepth,
                         bytes: Measure.measure(url).bytes, lastActivity: nil, verdict: verdict)
    }

    func testDeletesCandidateAndReportsFreedBytes() {
        let h = TempHome()
        h.file("Projects/app/.next/blob.bin", bytes: 80_000)
        let report = Cleaner(env: h.env()).run([candidate(h, "Projects/app/.next", root: "Projects")], dryRun: false)
        XCTAssertFalse(h.exists("Projects/app/.next"))
        XCTAssertTrue(h.exists("Projects/app"))
        XCTAssertEqual(report.deleted.count, 1)
        XCTAssertGreaterThanOrEqual(report.freedBytes, 80_000)
        XCTAssertEqual(report.errors, [])
    }

    func testDryRunDeletesNothingButReportsWhatItWould() {
        let h = TempHome()
        h.file("Projects/app/.next/blob.bin", bytes: 80_000)
        let report = Cleaner(env: h.env()).run([candidate(h, "Projects/app/.next", root: "Projects")], dryRun: true)
        XCTAssertTrue(h.exists("Projects/app/.next/blob.bin"))
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.deleted.count, 1)
    }

    func testKeepVerdictIsNeverDeleted() {
        let h = TempHome()
        h.file("Projects/app/.next/blob.bin")
        let c = candidate(h, "Projects/app/.next", root: "Projects", verdict: .keep(reason: "最近在用"))
        let report = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists("Projects/app/.next/blob.bin"))
        XCTAssertEqual(report.deleted, [])
    }

    func testRefusesCandidateOutsideItsRoot() {
        let h = TempHome()
        h.dir("Projects")
        h.file("Documents/thesis/.next/blob.bin")
        let report = Cleaner(env: h.env()).run([candidate(h, "Documents/thesis/.next", root: "Projects")], dryRun: false)
        XCTAssertTrue(h.exists("Documents/thesis/.next/blob.bin"))
        XCTAssertEqual(report.deleted, [])
        XCTAssertEqual(report.errors.count, 1)
    }

    func testRefusesSymlinkCandidateAndLeavesItsTargetIntact() throws {
        let h = TempHome()
        h.file("Precious/data.bin")
        h.dir("Projects/app")
        try FileManager.default.createSymbolicLink(at: h.path("Projects/app/.next"), withDestinationURL: h.path("Precious"))
        let c = Candidate(rule: .buildCaches, url: h.path("Projects/app/.next"), root: h.path("Projects"),
                          bytes: 0, lastActivity: nil, verdict: .delete(reason: "测试"))
        let report = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists("Precious/data.bin"))
        XCTAssertEqual(report.deleted, [])
        XCTAssertEqual(report.errors.count, 1)
    }

    func testRefusesAnythingUnderAMemoryDirectory() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/memory/MEMORY.md")
        let c = candidate(h, ".claude/projects/-Users-x/memory", root: ".claude/projects", rule: .conversations)
        let report = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists(".claude/projects/-Users-x/memory/MEMORY.md"))
        XCTAssertEqual(report.errors.count, 1)
    }

    func testRefusesTooShallowPackageCachePath() {
        let h = TempHome()
        h.file("Library/keep.bin")
        let c = candidate(h, "Library", root: "", rule: .packageCaches, minDepth: 2)
        _ = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists("Library/keep.bin"))
    }

    func testDeletesExtraPathsTogetherWithThePrimary() {
        let h = TempHome()
        h.file(".claude/projects/p/abc.jsonl")
        h.file(".claude/projects/p/abc/tool-results/a.txt")
        let c = candidate(h, ".claude/projects/p/abc.jsonl", root: ".claude/projects", rule: .conversations,
                          extra: [".claude/projects/p/abc"])
        _ = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertFalse(h.exists(".claude/projects/p/abc.jsonl"))
        XCTAssertFalse(h.exists(".claude/projects/p/abc"))
    }

    func testDeletesNothingWhenAnExtraPathFailsValidation() {
        let h = TempHome()
        h.file(".claude/projects/p/abc.jsonl")
        h.file("Elsewhere/abc/a.txt")
        let c = candidate(h, ".claude/projects/p/abc.jsonl", root: ".claude/projects", rule: .conversations,
                          extra: ["Elsewhere/abc"])
        let report = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists(".claude/projects/p/abc.jsonl"))
        XCTAssertTrue(h.exists("Elsewhere/abc/a.txt"))
        XCTAssertEqual(report.deleted, [])
    }

    func testSymlinkInsideDeletedTreeDoesNotTouchItsTarget() throws {
        let h = TempHome()
        h.file("Precious/data.bin")
        h.file("Projects/app/.next/blob.bin")
        try FileManager.default.createSymbolicLink(at: h.path("Projects/app/.next/link"), withDestinationURL: h.path("Precious"))
        _ = Cleaner(env: h.env()).run([candidate(h, "Projects/app/.next", root: "Projects")], dryRun: false)
        XCTAssertFalse(h.exists("Projects/app/.next"))
        XCTAssertTrue(h.exists("Precious/data.bin"))
    }

    func testPrunesEmptiedSessionDateDirectoriesButNotTheRoot() {
        let h = TempHome()
        h.file(".codex/sessions/2026/09/30/rollout-a.jsonl")
        let c = candidate(h, ".codex/sessions/2026/09/30/rollout-a.jsonl", root: ".codex/sessions", rule: .conversations)
        _ = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertFalse(h.exists(".codex/sessions/2026"))
        XCTAssertTrue(h.exists(".codex/sessions"))
    }

    func testDoesNotPruneDirectoriesThatStillHaveContent() {
        let h = TempHome()
        h.file(".codex/sessions/2026/09/30/rollout-a.jsonl")
        h.file(".codex/sessions/2026/09/30/rollout-b.jsonl")
        let c = candidate(h, ".codex/sessions/2026/09/30/rollout-a.jsonl", root: ".codex/sessions", rule: .conversations)
        _ = Cleaner(env: h.env()).run([c], dryRun: false)
        XCTAssertTrue(h.exists(".codex/sessions/2026/09/30/rollout-b.jsonl"))
    }

    func testDoesNotPruneParentsOfBuildCaches() {
        let h = TempHome()
        h.file("Projects/app/.next/blob.bin")
        _ = Cleaner(env: h.env()).run([candidate(h, "Projects/app/.next", root: "Projects")], dryRun: false)
        XCTAssertTrue(h.exists("Projects/app"))
    }

    func testAppendsOneLogLinePerDeletion() throws {
        let h = TempHome()
        h.file("Projects/a/.next/blob.bin")
        h.file("Projects/b/.next/blob.bin")
        let env = h.env()
        _ = Cleaner(env: env).run([candidate(h, "Projects/a/.next", root: "Projects"),
                                   candidate(h, "Projects/b/.next", root: "Projects")], dryRun: false)
        let lines = try String(contentsOf: env.logFile, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("DELETE") }.count, 2)
        XCTAssertTrue(lines.contains { $0.contains("Projects/a/.next") })
    }
}

final class RunnerTests: XCTestCase {
    let rollout = ".codex/sessions/2026/10/01/rollout-2026-10-01T00-00-00-01a130dd-f6c0-71a0-8d0b-2948f138ed6c.jsonl"

    /// 一个 9 天没动的 Codex 会话，加一个 9 天没动的 .next 缓存。
    private func stale() -> TempHome {
        let h = TempHome()
        h.file(rollout, bytes: 30_000)
        h.age(".codex", daysAgo: 9)
        h.file("Projects/app/package.json", text: "{}")
        h.file("Projects/app/.next/blob.bin", bytes: 60_000)
        h.age("Projects/app/.next", daysAgo: 9)
        return h
    }

    private func arm(_ h: TempHome) throws {
        var s = State()
        s.armed = true
        try s.save(to: h.env().stateFile)
    }

    func testScheduledRunWhileNotArmedDeletesNothing() throws {
        let h = stale()
        let outcome = try Runner(env: h.env()).run(mode: .scheduled)
        XCTAssertTrue(h.exists(rollout))
        XCTAssertTrue(h.exists("Projects/app/.next/blob.bin"))
        XCTAssertNil(outcome.report)
        XCTAssertGreaterThanOrEqual(outcome.pendingBytes, 90_000)
    }

    func testScheduledRunWhenArmedDeletes() throws {
        let h = stale()
        try arm(h)
        let outcome = try Runner(env: h.env()).run(mode: .scheduled)
        XCTAssertFalse(h.exists(rollout))
        XCTAssertFalse(h.exists("Projects/app/.next"))
        XCTAssertEqual(outcome.report?.deleted.count, 2)
    }

    func testManualRunDeletesEvenWhenNotArmed() throws {
        let h = stale()
        _ = try Runner(env: h.env()).run(mode: .manual)
        XCTAssertFalse(h.exists(rollout))
    }

    func testManualRunDoesNotArmScheduledRuns() throws {
        let h = stale()
        _ = try Runner(env: h.env()).run(mode: .manual)
        XCTAssertFalse(State.load(from: h.env().stateFile).armed)
    }

    func testDryRunDeletesNothingAndLeavesStateUntouched() throws {
        let h = stale()
        let outcome = try Runner(env: h.env()).run(mode: .manual, dryRun: true)
        XCTAssertTrue(h.exists(rollout))
        XCTAssertEqual(outcome.report?.deleted.count, 2)
        XCTAssertNil(State.load(from: h.env().stateFile).lastRun)
    }

    func testRunRecordsStateAndAccumulatesTotal() throws {
        let h = stale()
        try arm(h)
        let first = try Runner(env: h.env()).run(mode: .scheduled)
        var state = State.load(from: h.env().stateFile)
        XCTAssertNotNil(state.lastRun)
        XCTAssertEqual(state.lastFreedBytes, first.report?.freedBytes)
        XCTAssertEqual(state.lastDeletedCount, 2)

        h.file("Projects/app/.next/blob.bin", bytes: 60_000)
        h.age("Projects/app/.next", daysAgo: 9)
        let second = try Runner(env: h.env()).run(mode: .scheduled)
        state = State.load(from: h.env().stateFile)
        XCTAssertEqual(state.totalFreedBytes, first.report!.freedBytes + second.report!.freedBytes)
        XCTAssertTrue(state.armed)
    }

    func testCorruptConfigAbortsBeforeDeletingAnything() throws {
        let h = stale()
        try arm(h)
        h.file("Library/Application Support/Sweep/config.json", text: "{ broken")
        XCTAssertThrowsError(try Runner(env: h.env()).run(mode: .scheduled))
        XCTAssertTrue(h.exists(rollout))
        XCTAssertTrue(h.exists("Projects/app/.next/blob.bin"))
    }

    func testRuleDisabledInConfigFileIsRespected() throws {
        let h = stale()
        try arm(h)
        h.file("Library/Application Support/Sweep/config.json", text: #"{"conversations": {"enabled": false}}"#)
        _ = try Runner(env: h.env()).run(mode: .scheduled)
        XCTAssertTrue(h.exists(rollout))
        XCTAssertFalse(h.exists("Projects/app/.next"))
    }

    func testReportsCachesBlockedByARunningProcess() throws {
        let h = stale()
        try arm(h)
        let outcome = try Runner(env: h.env(inUse: { _, _ in true })).run(mode: .scheduled)
        XCTAssertTrue(h.exists("Projects/app/.next/blob.bin"))
        XCTAssertEqual(outcome.blocked.map(\.url.lastPathComponent), [".next"])
    }

    func testWorkCopiesAreLeftAloneByRuns() throws {
        let h = stale()
        try arm(h)
        h.file("Projects/api-worktrees/wt-old/src/main.py")
        h.age("Projects/api-worktrees", daysAgo: 300)
        _ = try Runner(env: h.env()).run(mode: .scheduled)
        XCTAssertTrue(h.exists("Projects/api-worktrees/wt-old/src/main.py"))
    }
}

extension CleanerTests {
    func testRotatesLogOnceItGrowsPastTheLimit() throws {
        let h = TempHome()
        let env = h.env()
        h.file("Library/Logs/Sweep/sweep.log", bytes: 6 << 20)
        h.file("Projects/a/.next/blob.bin")
        let c = Candidate(rule: .buildCaches, url: h.path("Projects/a/.next"), root: h.path("Projects"),
                          bytes: 1, lastActivity: nil, verdict: .delete(reason: "测试"))
        _ = Cleaner(env: env).run([c], dryRun: false)
        XCTAssertTrue(h.exists("Library/Logs/Sweep/sweep.log.1"))
        let size = try FileManager.default.attributesOfItem(atPath: env.logFile.path)[.size] as! Int64
        XCTAssertLessThan(size, 10_000)
    }
}
