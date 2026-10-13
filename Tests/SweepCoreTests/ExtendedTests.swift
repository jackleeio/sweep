import XCTest
@testable import SweepCore

private func scan(_ h: TempHome, _ rule: RuleID, config: Config = Config(), tight: Bool = false,
                  inUse: @escaping (URL, CacheKind) -> Bool = { _, _ in false }) -> [Candidate] {
    let env = h.env(inUse: inUse)
    return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile), tight: tight).scan(rules: [rule])
}

final class ExtendedConfigTests: XCTestCase {
    func testDefaultsForSpaceThresholdsAndNewRules() {
        let c = Config()
        XCTAssertEqual(c.lowSpaceGB, 100)
        XCTAssertEqual(c.targetFreeGB, 300)
        XCTAssertTrue(c.dependencies.enabled)
        XCTAssertEqual(c.dependencies.idleDays, 14)
        XCTAssertTrue(c.appCaches.enabled)
        XCTAssertEqual(c.excludes, [])
        XCTAssertTrue(c.packageCaches.paths.contains("~/.bun/install/cache"))
        XCTAssertTrue(c.packageCaches.paths.contains("~/.docker/scout"))
    }

    func testOldConfigFileWithoutNewKeysStillLoads() throws {
        let h = TempHome()
        let f = h.file("config.json", text: #"{"idleDays": 5}"#)
        let c = try Config.load(from: f)
        XCTAssertEqual(c.lowSpaceGB, 100)
        XCTAssertEqual(c.dependencies.idleDays, 14)
    }
}

final class UnreadableMeasureTests: XCTestCase {
    func testFlagsTreeContainingUnreadableDirectory() throws {
        let h = TempHome()
        h.file("d/ok.bin")
        h.file("d/locked/secret.bin")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: h.path("d/locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.path("d/locked").path) }
        XCTAssertTrue(Measure.measure(h.path("d")).unreadable)
    }

    func testFullyReadableTreeIsNotFlagged() {
        let h = TempHome()
        h.file("d/sub/ok.bin")
        XCTAssertFalse(Measure.measure(h.path("d")).unreadable)
    }
}

final class AppCacheRuleTests: XCTestCase {
    func testIdleAppCacheIsDeletable() {
        let h = TempHome()
        h.file("Library/Caches/com.example.oldapp/data.bin", bytes: 40_000)
        h.age("Library/Caches/com.example.oldapp", daysAgo: 5)
        let c = scan(h, .appCaches)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), ["com.example.oldapp"])
        XCTAssertEqual(c[0].root.path, h.path("Library/Caches").path)
    }

    func testAppCacheStillBeingWrittenIsKept() {
        let h = TempHome()
        h.file("Library/Caches/com.example.active/data.bin")
        let c = scan(h, .appCaches)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    /// 系统缓存，以及名义上在 Caches 里、实际是装好的浏览器内核的目录，删了不会自动恢复。
    func testSystemCachesAndInstalledBrowsersAreNeverCandidates() {
        let h = TempHome()
        h.file("Library/Caches/com.apple.Safari/x.bin")
        h.file("Library/Caches/ms-playwright/chromium-1/chrome")
        h.file("Library/Caches/ms-playwright-go/1.0/driver")
        h.file("Library/Caches/Cypress/13.0/app")
        h.age("Library/Caches", daysAgo: 90)
        XCTAssertEqual(scan(h, .appCaches), [])
    }

    func testEntriesOwnedByOtherRulesAreNotListedTwice() {
        let h = TempHome()
        h.file("Library/Caches/Yarn/v6/a.tgz")
        h.file("Library/Caches/pip/a.whl")
        h.file("Library/Caches/bnbot-codex-qa/out.bin")
        h.age("Library/Caches", daysAgo: 90)
        XCTAssertEqual(scan(h, .appCaches), [])
    }

    func testCacheThatCannotBeFullyReadIsKept() throws {
        let h = TempHome()
        h.file("Library/Caches/com.example.locked/inner/x.bin")
        h.age("Library/Caches/com.example.locked", daysAgo: 30)
        let locked = h.path("Library/Caches/com.example.locked/inner").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked) }
        let c = scan(h, .appCaches)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }
}

final class DependencyRuleTests: XCTestCase {
    /// 一个带依赖目录的 Node 项目，整体 daysAgo 天没动。
    private func nodeProject(_ h: TempHome, _ rel: String, daysAgo: Double, git: Bool = false) {
        h.file("\(rel)/package.json", text: "{}")
        h.file("\(rel)/src/index.ts", text: "export {}")
        h.file("\(rel)/node_modules/dep/index.js", bytes: 30_000)
        if git { h.file("\(rel)/.git/HEAD", text: "ref: refs/heads/main") }
        h.age(rel, daysAgo: daysAgo)
    }

    func testNodeModulesOfIdleProjectIsDeletable() {
        let h = TempHome()
        nodeProject(h, "Projects/old", daysAgo: 20)
        let c = scan(h, .dependencies)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), ["node_modules"])
        XCTAssertEqual(c[0].root.path, h.path("Projects").path)
    }

    func testNodeModulesKeptWhenProjectWasTouchedRecently() {
        let h = TempHome()
        nodeProject(h, "Projects/app", daysAgo: 20)
        h.age("Projects/app/src/index.ts", daysAgo: 2)
        let c = scan(h, .dependencies)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    /// 刚装过依赖的项目，即使源码很久没动，也不该马上被清。
    func testRecentInstallCountsAsActivity() {
        let h = TempHome()
        nodeProject(h, "Projects/app", daysAgo: 60)
        h.age("Projects/app/node_modules/dep", daysAgo: 1)
        XCTAssertEqual(scan(h, .dependencies).deletable, [])
    }

    func testGitActivityCountsEvenWhenFilesAreOld() {
        let h = TempHome()
        nodeProject(h, "Projects/app", daysAgo: 60, git: true)
        h.file("Projects/app/.git/index")
        XCTAssertEqual(scan(h, .dependencies).deletable, [])
    }

    func testNodeModulesWithoutPackageJsonIsIgnored() {
        let h = TempHome()
        h.file("Projects/stuff/node_modules/dep/index.js")
        h.age("Projects/stuff", daysAgo: 90)
        XCTAssertEqual(scan(h, .dependencies), [])
    }

    func testPackagesInOneRepositoryShareItsActivity() {
        let h = TempHome()
        h.file("Projects/mono/.git/HEAD", text: "ref: refs/heads/main")
        nodeProject(h, "Projects/mono/apps/a", daysAgo: 60)
        nodeProject(h, "Projects/mono/apps/b", daysAgo: 60)
        h.age("Projects/mono", daysAgo: 60)
        h.age("Projects/mono/apps/b/src/index.ts", daysAgo: 1)
        let c = scan(h, .dependencies)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.deletable, [])
    }

    func testEachWorktreeIsJudgedOnItsOwn() {
        let h = TempHome()
        nodeProject(h, "Projects/api-worktrees/wt-old", daysAgo: 40)
        nodeProject(h, "Projects/api-worktrees/wt-new", daysAgo: 40)
        h.file("Projects/api-worktrees/wt-old/.git", text: "gitdir: /x")
        h.file("Projects/api-worktrees/wt-new/.git", text: "gitdir: /x")
        h.age("Projects/api-worktrees", daysAgo: 40)
        h.age("Projects/api-worktrees/wt-new/src/index.ts", daysAgo: 1)
        let c = scan(h, .dependencies)
        XCTAssertEqual(c.deletable.map { $0.url.deletingLastPathComponent().lastPathComponent }, ["wt-old"])
    }

    func testVirtualEnvOfIdleProjectWithLockfileIsDeletable() {
        let h = TempHome()
        h.file("Projects/svc/uv.lock")
        h.file("Projects/svc/.venv/pyvenv.cfg")
        h.file("Projects/svc/.venv/lib/site.py", bytes: 20_000)
        h.age("Projects/svc", daysAgo: 30)
        XCTAssertEqual(scan(h, .dependencies).deletable.map(\.url.lastPathComponent), [".venv"])
    }

    /// 没有锁文件或 requirements 的虚拟环境无法照原样重建，不碰。
    func testVirtualEnvThatCannotBeRebuiltIsIgnored() {
        let h = TempHome()
        h.file("Projects/svc/.venv/pyvenv.cfg")
        h.file("Projects/svc/main.py")
        h.age("Projects/svc", daysAgo: 30)
        XCTAssertEqual(scan(h, .dependencies), [])
    }

    func testDirectoryNamedVenvWithoutPyvenvCfgIsIgnored() {
        let h = TempHome()
        h.file("Projects/svc/requirements.txt")
        h.file("Projects/svc/venv/notes.txt")
        h.age("Projects/svc", daysAgo: 30)
        XCTAssertEqual(scan(h, .dependencies), [])
    }

    func testDependenciesOfProjectWithRunningProcessAreKept() {
        let h = TempHome()
        nodeProject(h, "Projects/daemon", daysAgo: 40)
        var kinds: [CacheKind] = []
        let c = scan(h, .dependencies) { _, kind in
            kinds.append(kind)
            return true
        }
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(kinds, [.dependencies])
    }

    func testTightModeShortensTheIdleThreshold() {
        let h = TempHome()
        nodeProject(h, "Projects/app", daysAgo: 5)
        XCTAssertEqual(scan(h, .dependencies).deletable, [])
        XCTAssertEqual(scan(h, .dependencies, tight: true).deletable.count, 1)
    }

    func testDisabledRuleYieldsNothing() {
        let h = TempHome()
        nodeProject(h, "Projects/old", daysAgo: 40)
        var config = Config()
        config.dependencies.enabled = false
        XCTAssertEqual(scan(h, .dependencies, config: config), [])
    }
}

final class TightModeTests: XCTestCase {
    private func nextCache(_ h: TempHome, hoursAgo: Double) {
        h.file("Projects/app/package.json", text: "{}")
        h.file("Projects/app/.next/blob.bin", bytes: 40_000)
        h.age("Projects/app/.next", daysAgo: hoursAgo / 24)
    }

    func testBuildCacheIdleForHoursIsOnlyDeletableInTightMode() {
        let h = TempHome()
        nextCache(h, hoursAgo: 5)
        XCTAssertEqual(scan(h, .buildCaches).deletable, [])
        XCTAssertEqual(scan(h, .buildCaches, tight: true).deletable.count, 1)
    }

    func testCacheWrittenWithinTheHourIsKeptEvenInTightMode() {
        let h = TempHome()
        nextCache(h, hoursAgo: 0.2)
        XCTAssertEqual(scan(h, .buildCaches, tight: true).deletable, [])
    }

    func testTightModeClearsPackageCachesRegardlessOfCap() {
        let h = TempHome()
        h.file("Library/Caches/Yarn/v6/a.tgz", bytes: 50_000)
        XCTAssertEqual(scan(h, .packageCaches).deletable, [])
        XCTAssertEqual(scan(h, .packageCaches, tight: true).deletable.count, 1)
    }

    func testTightModeAppliesToAgentTempAndAppCaches() {
        let h = TempHome()
        h.file(".cache/bnbot-layout-abc/out.bin")
        h.file("Library/Caches/com.example.app/data.bin")
        h.age(".cache", daysAgo: 0.3)
        h.age("Library/Caches", daysAgo: 0.3)
        XCTAssertEqual(scan(h, .agentTemp, tight: true).deletable.count, 1)
        XCTAssertEqual(scan(h, .appCaches, tight: true).deletable.count, 1)
    }

    /// 空间再紧张，也不加快删除对话。
    func testTightModeNeverSpeedsUpConversationDeletion() {
        let h = TempHome()
        h.file(".codex/sessions/2026/10/12/rollout-2026-10-12T00-00-00-01a130dd-f6c0-71a0-8d0b-2948f138ed6c.jsonl")
        h.age(".codex", daysAgo: 2)
        XCTAssertEqual(scan(h, .conversations, tight: true).deletable, [])
    }
}

final class ExcludeTests: XCTestCase {
    private func setUpCache(_ h: TempHome) {
        h.file("Projects/app/package.json", text: "{}")
        h.file("Projects/app/.next/blob.bin")
        h.age("Projects/app/.next", daysAgo: 30)
    }

    func testCandidateInsideAnExcludedPathIsDropped() {
        let h = TempHome()
        setUpCache(h)
        var config = Config()
        config.excludes = ["~/Projects/app"]
        XCTAssertEqual(scan(h, .buildCaches, config: config), [])
    }

    func testCandidateContainingAnExcludedPathIsDropped() {
        let h = TempHome()
        setUpCache(h)
        var config = Config()
        config.excludes = ["~/Projects/app/.next/keep-me"]
        XCTAssertEqual(scan(h, .buildCaches, config: config), [])
    }

    func testUnrelatedExcludeDoesNotAffectOtherCandidates() {
        let h = TempHome()
        setUpCache(h)
        var config = Config()
        config.excludes = ["~/Projects/app2"]
        XCTAssertEqual(scan(h, .buildCaches, config: config).deletable.count, 1)
    }
}

final class TickTests: XCTestCase {
    private let gb = Int64(Format.gigabyte)

    /// 一个 9 天没动的 .next，加一个 5 小时没动的 .next（只有收紧模式才会清）。
    private func home() -> TempHome {
        let h = TempHome()
        h.file("Projects/old/package.json", text: "{}")
        h.file("Projects/old/.next/blob.bin", bytes: 40_000)
        h.age("Projects/old/.next", daysAgo: 9)
        h.file("Projects/warm/package.json", text: "{}")
        h.file("Projects/warm/.next/blob.bin", bytes: 40_000)
        h.age("Projects/warm/.next", daysAgo: 5.0 / 24)
        return h
    }

    private func save(_ h: TempHome, armed: Bool = true, _ edit: (inout SweepState) -> Void = { _ in }) throws {
        var s = SweepState()
        s.armed = armed
        edit(&s)
        try s.save(to: h.env().stateFile)
    }

    private func tick(_ h: TempHome, freeGB: Int64) throws -> TickOutcome {
        try Runner(env: h.env(free: { freeGB * self.gb })).tick()
    }

    func testDoesNothingWhenDailyRunIsRecentAndSpaceIsFine() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now }
        let outcome = try tick(h, freeGB: 500)
        XCTAssertEqual(outcome.action, .none)
        XCTAssertTrue(h.exists("Projects/old/.next"))
    }

    func testRunsDailyCleanOnceADayHasPassed() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now.addingTimeInterval(-25 * 3600) }
        let outcome = try tick(h, freeGB: 500)
        XCTAssertEqual(outcome.action, .daily)
        XCTAssertFalse(h.exists("Projects/old/.next"))
        XCTAssertTrue(h.exists("Projects/warm/.next"))
        XCTAssertNotNil(SweepState.load(from: h.env().stateFile).lastDailyRun)
    }

    func testFirstTickAfterArmingRunsImmediately() throws {
        let h = home()
        try save(h)
        XCTAssertEqual(try tick(h, freeGB: 500).action, .daily)
    }

    func testCleansImmediatelyWhenFreeSpaceDropsBelowTheFloor() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now }
        let outcome = try tick(h, freeGB: 60)
        XCTAssertEqual(outcome.action, .emergency)
        XCTAssertFalse(h.exists("Projects/old/.next"))
        XCTAssertFalse(h.exists("Projects/warm/.next"))
    }

    func testEmergencyCleanRunsAtMostOncePerHour() throws {
        let h = home()
        try save(h) {
            $0.lastDailyRun = h.now
            $0.lastTightRun = h.now.addingTimeInterval(-20 * 60)
        }
        let outcome = try tick(h, freeGB: 60)
        XCTAssertEqual(outcome.action, .none)
        XCTAssertTrue(h.exists("Projects/warm/.next"))
    }

    func testDailyCleanTightensWhenStillBelowTheTarget() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now.addingTimeInterval(-25 * 3600) }
        let outcome = try tick(h, freeGB: 200)
        XCTAssertEqual(outcome.action, .daily)
        XCTAssertFalse(h.exists("Projects/warm/.next"))
        XCTAssertEqual(outcome.reports.count, 2)
    }

    func testDailyCleanStaysNormalWhenAboveTheTarget() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now.addingTimeInterval(-25 * 3600) }
        let outcome = try tick(h, freeGB: 350)
        XCTAssertTrue(h.exists("Projects/warm/.next"))
        XCTAssertEqual(outcome.reports.count, 1)
    }

    func testUnconfirmedTickNeverDeletesEvenWhenSpaceIsLow() throws {
        let h = home()
        try save(h, armed: false)
        let outcome = try tick(h, freeGB: 10)
        XCTAssertEqual(outcome.action, .pendingConfirmation)
        XCTAssertTrue(h.exists("Projects/old/.next"))
        XCTAssertGreaterThan(outcome.pendingBytes, 0)
    }

    func testUnconfirmedTickAsksForConfirmationOnlyOnceADay() throws {
        let h = home()
        try save(h, armed: false)
        XCTAssertEqual(try tick(h, freeGB: 10).action, .pendingConfirmation)
        XCTAssertEqual(try tick(h, freeGB: 10).action, .none)
    }

    func testReportsWhenSpaceIsStillBelowTheFloorAfterCleaning() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now }
        XCTAssertTrue(try tick(h, freeGB: 60).stillLow)
    }

    func testStillLowNoticeIsRaisedAtMostOncePerDay() throws {
        let h = home()
        try save(h) {
            $0.lastDailyRun = h.now
            $0.lastLowSpaceNotice = h.now.addingTimeInterval(-2 * 3600)
        }
        XCTAssertFalse(try tick(h, freeGB: 60).stillLow)
    }

    func testAccumulatesFreedBytesAcrossBothPasses() throws {
        let h = home()
        try save(h) { $0.lastDailyRun = h.now.addingTimeInterval(-25 * 3600) }
        let outcome = try tick(h, freeGB: 200)
        let state = SweepState.load(from: h.env().stateFile)
        XCTAssertEqual(state.lastDeletedCount, 2)
        XCTAssertEqual(state.totalFreedBytes, outcome.reports.reduce(0) { $0 + $1.freedBytes })
    }
}

final class BuiltInListTests: XCTestCase {
    /// 旧版本把整份路径列表写进了配置文件。升级后新增的内置路径不能被它盖住。
    func testListsSavedByOlderVersionsDoNotHideNewBuiltIns() throws {
        let h = TempHome()
        let f = h.file("config.json", text: #"{"packageCaches": {"enabled": true, "paths": ["~/Library/Caches/Yarn"], "totalCapGB": 20}, "agentTemp": {"globs": ["~/.cache/old-*"]}}"#)
        let c = try Config.load(from: f)
        XCTAssertTrue(c.packageCaches.paths.contains("~/.bun/install/cache"))
        XCTAssertTrue(c.agentTemp.globs.contains("~/.cache/bnbot-*"))
        XCTAssertFalse(c.agentTemp.globs.contains("~/.cache/old-*"))
    }

    func testUserAdditionsAreAppendedToBuiltIns() throws {
        let h = TempHome()
        var c = Config()
        c.packageCaches.extraPaths = ["~/.cache/huggingface"]
        c.conversations.extraClaudeRoots = ["~/.bnbot/projects"]
        c.appCaches.extraSkipPrefixes = ["com.example.keep"]
        try c.save(to: h.path("config.json"))
        let loaded = try Config.load(from: h.path("config.json"))
        XCTAssertTrue(loaded.packageCaches.paths.contains("~/.cache/huggingface"))
        XCTAssertTrue(loaded.packageCaches.paths.contains("~/.npm/_cacache"))
        XCTAssertEqual(loaded.conversations.claudeRoots, ["~/.claude/projects", "~/.bnbot/projects"])
        XCTAssertTrue(loaded.appCaches.skipPrefixes.contains("com.example.keep"))
        XCTAssertTrue(loaded.appCaches.skipPrefixes.contains("com.apple."))
    }

    func testSavedFileContainsOnlyUserAdditionsNotBuiltIns() throws {
        let h = TempHome()
        try Config().save(to: h.path("config.json"))
        let text = try String(contentsOf: h.path("config.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("_cacache"))
        XCTAssertFalse(text.contains("bnbot-"))
    }
}
