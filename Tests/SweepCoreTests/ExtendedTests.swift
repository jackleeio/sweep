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
        XCTAssertEqual(c.conversations.idleDays, 7)
        XCTAssertEqual(c.claudeConversations.idleDays, 7)
        XCTAssertEqual(c.recordings.idleDays, 7)
        XCTAssertFalse(c.workCopies.enabled)
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
        c.claudeConversations.extraClaudeRoots = ["~/.bnbot/projects"]
        c.appCaches.extraSkipPrefixes = ["com.example.keep"]
        try c.save(to: h.path("config.json"))
        let loaded = try Config.load(from: h.path("config.json"))
        XCTAssertTrue(loaded.packageCaches.paths.contains("~/.cache/huggingface"))
        XCTAssertTrue(loaded.packageCaches.paths.contains("~/.npm/_cacache"))
        XCTAssertEqual(loaded.claudeConversations.claudeRoots, ["~/.claude/projects", "~/.bnbot/projects"])
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

final class AIToolCacheTests: XCTestCase {
    private func home() -> TempHome {
        let h = TempHome()
        for name in ["com.openai.atlas", "ChatGPTHelper", "ai.bnbot.app", "BNBot", "com.exafunction.windsurf.ShipIt",
                     "manus-updater", "com.google.GeminiMacOS", "claude-cli-nodejs", "com.todesktop.230313mzl4w4u92"] {
            h.file("Library/Caches/\(name)/data.bin", bytes: 20_000)
        }
        h.file("Library/Caches/Vivaldi/data.bin", bytes: 20_000)
        h.age("Library/Caches", daysAgo: 200)
        return h
    }

    /// AI 工具和 agent 的缓存默认保留，但仍然列出来，让用户看得到占了多少。
    func testAIToolCachesAreListedButKeptByDefault() {
        let c = scan(home(), .appCaches)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), ["Vivaldi"])
        XCTAssertEqual(c.count, 10)
        XCTAssertTrue(c.filter { !$0.isDelete }.allSatisfy { $0.reason.contains("AI") })
    }

    func testAIToolCachesStayKeptInTightMode() {
        XCTAssertEqual(scan(home(), .appCaches, tight: true).deletable.map(\.url.lastPathComponent), ["Vivaldi"])
    }

    func testAIToolCachesAreCleanedOnceTheUserOptsIn() {
        var config = Config()
        config.appCaches.keepAITools = false
        XCTAssertEqual(scan(home(), .appCaches, config: config).deletable.count, 10)
    }

    func testKeepAIToolsDefaultsToOnAndSurvivesRoundTrip() throws {
        let h = TempHome()
        XCTAssertTrue(Config().appCaches.keepAITools)
        var c = Config()
        c.appCaches.keepAITools = false
        try c.save(to: h.path("config.json"))
        XCTAssertFalse(try Config.load(from: h.path("config.json")).appCaches.keepAITools)
    }
}

final class RichSummaryTests: XCTestCase {
    private func item(_ path: String, _ bytes: Int64, _ verdict: Verdict, rule: RuleID = .buildCaches) -> Candidate {
        Candidate(rule: rule, url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/"), bytes: bytes,
                  lastActivity: nil, verdict: verdict)
    }

    func testKeepsTheLargestDeletableItemsOfEachRule() {
        let items = (1...12).map { item("/p/c\($0)", Int64($0), .delete(reason: "\($0) 天没更新")) }
        let rule = ScanSummary.make(from: items, date: Date())[.buildCaches]!
        XCTAssertEqual(rule.top.count, 8)
        XCTAssertEqual(rule.top.first, ScanItem(path: "/p/c12", bytes: 12, reason: "12 天没更新"))
        XCTAssertEqual(rule.top.map(\.bytes), [12, 11, 10, 9, 8, 7, 6, 5])
        XCTAssertEqual(rule.deletableCount, 12)
    }

    func testGroupsKeptItemsByReasonLargestFirst() {
        let rule = ScanSummary.make(from: [
            item("/a", 10, .keep(reason: "最近在用")),
            item("/b", 20, .keep(reason: "最近在用")),
            item("/c", 500, .keep(reason: "AI 工具的缓存，按设置保留")),
        ], date: Date())[.buildCaches]!
        XCTAssertEqual(rule.kept, [
            KeptGroup(reason: "AI 工具的缓存，按设置保留", count: 1, bytes: 500),
            KeptGroup(reason: "最近在用", count: 2, bytes: 30),
        ])
    }

    func testSummarySavedByOlderVersionStillLoads() throws {
        let h = TempHome()
        let old = #"{"date":"2026-10-13T13:35:00Z","rules":{"buildCaches":{"deletableBytes":5,"deletableCount":1,"keptBytes":2,"keptCount":1}}}"#
        let f = h.file("last-scan.json", text: old)
        let summary = try XCTUnwrap(ScanSummary.load(from: f))
        XCTAssertEqual(summary[.buildCaches]?.deletableBytes, 5)
        XCTAssertEqual(summary[.buildCaches]?.top, [])
    }
}

final class HistoryTests: XCTestCase {
    private func home() -> TempHome {
        let h = TempHome()
        h.file("Projects/old/package.json", text: "{}")
        h.file("Projects/old/.next/blob.bin", bytes: 40_000)
        h.age("Projects/old/.next", daysAgo: 9)
        return h
    }

    func testManualRunIsAppendedToHistory() throws {
        let h = home()
        let outcome = try Runner(env: h.env()).run(mode: .manual)
        let history = SweepState.load(from: h.env().stateFile).history
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].kind, "manual")
        XCTAssertEqual(history[0].deletedCount, 1)
        XCTAssertEqual(history[0].freedBytes, outcome.report?.freedBytes)
    }

    func testTickRecordsWhyItRan() throws {
        let h = home()
        var s = SweepState()
        s.armed = true
        s.lastDailyRun = h.now
        try s.save(to: h.env().stateFile)
        _ = try Runner(env: h.env(free: { 60 * Int64(Format.gigabyte) })).tick()
        XCTAssertEqual(SweepState.load(from: h.env().stateFile).history.map(\.kind), ["emergency"])
    }

    func testDryRunIsNotRecorded() throws {
        let h = home()
        _ = try Runner(env: h.env()).run(mode: .manual, dryRun: true)
        XCTAssertEqual(SweepState.load(from: h.env().stateFile).history, [])
    }

    func testHistoryKeepsOnlyTheMostRecentRuns() throws {
        let h = home()
        var s = SweepState()
        s.history = (0..<30).map { RunRecord(date: h.now, kind: "daily", deletedCount: $0, freedBytes: 1, errorCount: 0) }
        try s.save(to: h.env().stateFile)
        _ = try Runner(env: h.env()).run(mode: .manual)
        let history = SweepState.load(from: h.env().stateFile).history
        XCTAssertEqual(history.count, 20)
        XCTAssertEqual(history.last?.kind, "manual")
        XCTAssertEqual(history.first?.deletedCount, 11)
    }

    func testStateSavedByOlderVersionStillLoadsAndKeepsArmedFlag() throws {
        let h = TempHome()
        h.file("Library/Application Support/Sweep/state.json", text: #"{"armed":true,"lastDeletedCount":0,"lastErrorCount":0,"lastFreedBytes":0,"totalFreedBytes":0}"#)
        let state = SweepState.load(from: h.env().stateFile)
        XCTAssertTrue(state.armed)
        XCTAssertEqual(state.history, [])
    }
}

final class RuleDetailTests: XCTestCase {
    /// 说明文字里的阈值要跟着设置走，否则界面会和实际行为对不上。
    func testDetailReflectsConfiguredThresholds() {
        var config = Config()
        config.idleDays = 5
        config.buildCaches.sizeCapGB = 12
        config.dependencies.idleDays = 21
        config.packageCaches.totalCapGB = 35
        XCTAssertTrue(RuleID.buildCaches.detail(config).contains("5 天"))
        XCTAssertTrue(RuleID.buildCaches.detail(config).contains("12 GB"))
        XCTAssertTrue(RuleID.dependencies.detail(config).contains("21 天"))
        XCTAssertTrue(RuleID.packageCaches.detail(config).contains("35 GB"))
        XCTAssertTrue(RuleID.conversations.detail(config).contains("5 天"))
    }

    func testAppCacheDetailSaysWhetherAIToolCachesAreKept() {
        var config = Config()
        XCTAssertTrue(RuleID.appCaches.detail(config).contains("AI"))
        config.appCaches.keepAITools = false
        XCTAssertFalse(RuleID.appCaches.detail(config).contains("AI"))
    }

    func testEveryRuleHasADetail() {
        for rule in RuleID.allCases { XCTAssertFalse(rule.detail(Config()).isEmpty, "\(rule)") }
    }
}

final class InterruptedRunTests: XCTestCase {
    /// 清理可能中途被终止。每删完一项，日志里就必须已经有它的记录，而不是等整轮结束才写。
    func testLogLineIsWrittenBeforeTheNextItemIsTouched() {
        let h = TempHome()
        let env = h.env()
        h.file("Projects/a/.next/blob.bin")
        h.file("Projects/b/.next/blob.bin")
        let items = ["a", "b"].map {
            Candidate(rule: .buildCaches, url: h.path("Projects/\($0)/.next"), root: h.path("Projects"),
                      bytes: 1, lastActivity: nil, verdict: .delete(reason: "测试"))
        }
        var loggedSoFar: [Int] = []
        var secondStillThere = false
        _ = Cleaner(env: env).run(items, dryRun: false) { item in
            let log = (try? String(contentsOf: env.logFile, encoding: .utf8)) ?? ""
            loggedSoFar.append(log.split(separator: "\n").filter { $0.contains("DELETE") }.count)
            if item.path.hasSuffix("a/.next") { secondStillThere = h.exists("Projects/b/.next/blob.bin") }
        }
        XCTAssertEqual(loggedSoFar, [1, 2])
        XCTAssertTrue(secondStillThere)
    }
}

final class ExternalReferenceTests: XCTestCase {
    private func idleProject(_ h: TempHome, _ rel: String) {
        h.file("\(rel)/package.json", text: "{}")
        h.file("\(rel)/node_modules/dep/index.js", bytes: 20_000)
    }

    private func scan(_ h: TempHome, references: [String]) -> [Candidate] {
        var env = h.env()
        env.externalReferences = { references }
        return Scanner(config: Config(), env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.dependencies])
    }

    /// 全局 link 的命令、技能链接、定时任务会在项目「闲置」时照样用到它的依赖。
    func testDependenciesOfProjectReferencedFromOutsideAreKept() {
        let h = TempHome()
        h.file("Projects/kit/.git/HEAD", text: "ref: refs/heads/main")
        idleProject(h, "Projects/kit/cli")
        idleProject(h, "Projects/kit/extension")
        h.age("Projects/kit", daysAgo: 40)
        let c = scan(h, references: [h.path("Projects/kit/cli").path])
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.deletable, [])
        XCTAssertTrue(c.allSatisfy { $0.reason.contains("引用") })
    }

    func testReferenceIntoAnotherProjectDoesNotProtectThisOne() {
        let h = TempHome()
        idleProject(h, "Projects/kit")
        idleProject(h, "Projects/kit-legacy")
        h.age("Projects", daysAgo: 40)
        let c = scan(h, references: [h.path("Projects/kit/dist/index.js").path])
        XCTAssertEqual(c.deletable.map { $0.url.deletingLastPathComponent().lastPathComponent }, ["kit-legacy"])
    }

    func testReferenceComparisonIgnoresCase() {
        let h = TempHome()
        idleProject(h, "Projects/Kit")
        h.age("Projects", daysAgo: 40)
        XCTAssertEqual(scan(h, references: [h.path("projects/kit/cli").path]).deletable, [])
    }

    func testCollectsRealPathsOfSymlinksIncludingScopedPackages() throws {
        let h = TempHome()
        let fm = FileManager.default
        h.dir("Projects/kit/cli")
        h.dir("Projects/other")
        h.dir("global/node_modules/@bnbot")
        h.dir("global/node_modules/real-package")
        try fm.createSymbolicLink(at: h.path("global/node_modules/@bnbot/cli"), withDestinationURL: h.path("Projects/kit/cli"))
        try fm.createSymbolicLink(at: h.path("global/node_modules/other"), withDestinationURL: h.path("Projects/other"))
        try fm.createSymbolicLink(at: h.path("global/node_modules/dangling"), withDestinationURL: h.path("Projects/gone"))
        let found = ExternalReferences.linkTargets(in: [h.path("global/node_modules"), h.path("does/not/exist")])
        XCTAssertEqual(Set(found), [h.path("Projects/kit/cli").path, h.path("Projects/other").path])
    }

    func testCollectsAbsolutePathsFromLaunchAgentPlists() throws {
        let h = TempHome()
        let plist: [String: Any] = [
            "Label": "com.example.job",
            "ProgramArguments": ["/usr/bin/node", h.path("Projects/svc/run.js").path, "--flag"],
            "WorkingDirectory": h.path("Projects/svc").path,
            "EnvironmentVariables": ["DATA": h.path("Projects/data").path],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: h.path("Library/LaunchAgents"), withIntermediateDirectories: true)
        try data.write(to: h.path("Library/LaunchAgents/com.example.job.plist"))
        h.file("Library/LaunchAgents/broken.plist", text: "not a plist")
        let found = ExternalReferences.launchAgentPaths(in: h.path("Library/LaunchAgents"))
        XCTAssertTrue(found.contains(h.path("Projects/svc/run.js").path))
        XCTAssertTrue(found.contains(h.path("Projects/svc").path))
        XCTAssertTrue(found.contains(h.path("Projects/data").path))
        XCTAssertFalse(found.contains("--flag"))
    }
}
