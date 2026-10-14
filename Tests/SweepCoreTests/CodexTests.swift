import XCTest
@testable import SweepCore

private func scan(_ h: TempHome, config: Config = Config(), tight: Bool = false) -> [Candidate] {
    let env = h.env()
    return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile), tight: tight).scan(rules: [.conversations])
}

private func find(_ list: [Candidate], _ n: Int) -> Candidate {
    list.first { $0.url.lastPathComponent.contains(CodexFixture.id(n)) }!
}

final class CodexConversationTests: XCTestCase {
    func testIdleConversationIsDeletableAndLabelledByAgeBucket() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 12)
        codex.session(2, daysAgo: 40)
        codex.session(3, daysAgo: 200)
        let c = scan(h)
        XCTAssertEqual(c.deletable.count, 3)
        XCTAssertEqual(find(c, 1).category, "7–30 天没更新")
        XCTAssertEqual(find(c, 2).category, "30–90 天没更新")
        XCTAssertEqual(find(c, 3).category, "90 天以上没更新")
    }

    func testConversationIdleLessThanAWeekIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 1)
        codex.session(2, daysAgo: 5)
        let c = scan(h)
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(find(c, 1).category, "3 天内更新过")
        XCTAssertEqual(find(c, 2).category, "3–7 天没更新")
    }

    func testThresholdComesFromItsOwnSetting() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 5)
        var config = Config()
        config.conversations.idleDays = 4
        XCTAssertEqual(scan(h, config: config).deletable.count, 1)
    }

    func testConversationPinnedInCodexIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 300)
        codex.state(pinned: [1])
        let c = scan(h)
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(c[0].category, "Codex 里 pin 的")
    }

    func testConversationInThePinnedSectionIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 300, pinnedSection: true)
        XCTAssertEqual(scan(h)[0].category, "Codex 里 pin 的")
    }

    /// 置顶的是项目文件夹时，里面的对话在 Codex 的 Pinned 列表里同样可见，也要保留。
    func testConversationWhoseWorkingDirectoryBelongsToAPinnedProjectIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 300, cwd: "/Users/x/Projects/basic-english-850")
        codex.session(2, daysAgo: 300, cwd: "/Users/x/Projects/basic-english-850/sub")
        codex.session(3, daysAgo: 300, cwd: "/Users/x/Projects/basic-english-8500")
        codex.state(pinnedProjects: ["local-1"], projects: ["local-1": ["/Users/x/Projects/basic-english-850"], "local-2": ["/Users/x/Projects/other"]])
        let c = scan(h)
        XCTAssertEqual(find(c, 1).category, "在置顶项目里的")
        XCTAssertEqual(find(c, 2).category, "在置顶项目里的")
        XCTAssertTrue(find(c, 3).isDelete)
    }

    func testConversationAssignedToOrListedUnderAPinnedProjectIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 300)
        codex.session(2, daysAgo: 300)
        codex.session(3, daysAgo: 300)
        codex.state(pinnedProjects: ["p1"], assignments: [1: "p1", 3: "p-unpinned"], sidebar: ["p1": [2]])
        let c = scan(h)
        XCTAssertFalse(find(c, 1).isDelete)
        XCTAssertFalse(find(c, 2).isDelete)
        XCTAssertTrue(find(c, 3).isDelete)
    }

    func testArchivedConversationIsDeletableOnceItHasBeenQuietForThreeDays() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 4, archived: true)
        codex.session(2, daysAgo: 1, archived: true)
        codex.session(3, daysAgo: 4, inDatabase: false, directory: "archived_sessions")
        let c = scan(h)
        XCTAssertTrue(find(c, 1).isDelete)
        XCTAssertEqual(find(c, 1).category, "已归档")
        XCTAssertFalse(find(c, 2).isDelete)
        XCTAssertEqual(find(c, 3).category, "已归档")
    }

    func testPinnedWinsOverArchived() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 50, archived: true)
        codex.state(pinned: [1])
        XCTAssertEqual(scan(h).deletable, [])
    }

    func testSubagentSessionIsDeletedTogetherWithItsParent() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 40)
        codex.session(2, daysAgo: 40, role: "worker")
        codex.spawn(parent: 1, child: 2)
        let c = scan(h)
        XCTAssertTrue(find(c, 2).isDelete)
        XCTAssertEqual(find(c, 2).category, "子 agent 的会话")
    }

    /// 子 agent 的会话跟随所属对话：所属对话保留，它就保留，哪怕它自己很久没更新。
    func testSubagentSessionOfAKeptParentIsKept() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 1)
        codex.session(2, daysAgo: 30, role: "worker")
        codex.session(3, daysAgo: 300)
        codex.session(4, daysAgo: 300, role: "worker")
        codex.spawn(parent: 1, child: 2)
        codex.spawn(parent: 3, child: 4)
        codex.state(pinned: [3])
        let c = scan(h)
        XCTAssertFalse(find(c, 2).isDelete)
        XCTAssertFalse(find(c, 4).isDelete)
        XCTAssertEqual(find(c, 2).category, "子 agent（所属对话保留）")
    }

    func testNestedSubagentFollowsItsRootConversation() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 1)
        codex.session(2, daysAgo: 60, role: "worker")
        codex.session(3, daysAgo: 60, role: "worker")
        codex.spawn(parent: 1, child: 2)
        codex.spawn(parent: 2, child: 3)
        XCTAssertFalse(find(scan(h), 3).isDelete)
    }

    func testSubagentWhoseParentIsGoneFallsBackToItsOwnAge() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(2, daysAgo: 60, role: "worker")
        codex.session(3, daysAgo: 2, role: "worker")
        codex.spawn(parent: 99, child: 2)
        codex.spawn(parent: 99, child: 3)
        let c = scan(h)
        XCTAssertTrue(find(c, 2).isDelete)
        XCTAssertFalse(find(c, 3).isDelete)
    }

    func testSessionFileUnknownToCodexIsDeletableWhenIdle() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 20, inDatabase: false)
        codex.session(2, daysAgo: 2, inDatabase: false)
        let c = scan(h)
        XCTAssertTrue(find(c, 1).isDelete)
        XCTAssertEqual(find(c, 1).category, "Codex 里没有记录")
        XCTAssertFalse(find(c, 2).isDelete)
    }

    func testActivityRecordedInTheDatabaseCountsEvenIfTheFileIsOld() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 60, databaseDaysAgo: 1)
        XCTAssertEqual(scan(h).deletable, [])
    }

    /// 读不懂 Codex 的状态就无从知道哪些被 pin 了，这时一条都不能删。
    func testUnreadableDatabaseKeepsEveryConversation() {
        let h = TempHome()
        let codex = CodexFixture(h, database: false)
        codex.session(1, daysAgo: 300, inDatabase: false)
        h.file(".codex/state_5.sqlite", text: "this is not a database")
        let c = scan(h)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testUnparsableGlobalStateKeepsEveryConversation() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 300)
        h.file(".codex/.codex-global-state.json", text: "{ broken")
        XCTAssertEqual(scan(h).deletable, [])
    }

    func testWithoutAnyCodexStateFilesTheAgeRuleStillApplies() {
        let h = TempHome()
        let codex = CodexFixture(h, database: false)
        codex.session(1, daysAgo: 20, inDatabase: false)
        XCTAssertEqual(scan(h).deletable.count, 1)
    }

    func testSweepMarkProtectsACodexConversation() throws {
        let h = TempHome()
        let codex = CodexFixture(h)
        let pin = try PinStore(file: h.env().pinsFile).add(label: "调研", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        let rel = codex.session(1, daysAgo: 40)
        h.file(rel, text: "{\"output\":\"\(pin.token)\"}")
        h.age(rel, daysAgo: 40)
        let c = scan(h)
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(c[0].category, "已标记")
    }
}

final class SummaryGroupTests: XCTestCase {
    private func item(_ bytes: Int64, _ verdict: Verdict, _ category: String?) -> Candidate {
        Candidate(rule: .conversations, url: URL(fileURLWithPath: "/x/\(UUID().uuidString)"), root: URL(fileURLWithPath: "/"),
                  bytes: bytes, lastActivity: nil, verdict: verdict, category: category)
    }

    func testGroupsCandidatesByCategoryAndWhetherTheyWillBeDeleted() {
        let rule = ScanSummary.make(from: [
            item(100, .delete(reason: "40 天没更新"), "30–90 天没更新"),
            item(300, .delete(reason: "55 天没更新"), "30–90 天没更新"),
            item(50, .delete(reason: "已归档"), "已归档"),
            item(900, .keep(reason: "Codex 里 pin 的"), "Codex 里 pin 的"),
        ], date: Date())[.conversations]!
        XCTAssertEqual(rule.groups, [
            SummaryGroup(label: "30–90 天没更新", count: 2, bytes: 400, deletable: true),
            SummaryGroup(label: "已归档", count: 1, bytes: 50, deletable: true),
            SummaryGroup(label: "Codex 里 pin 的", count: 1, bytes: 900, deletable: false),
        ])
    }

    func testItemsWithoutCategoryFallBackToReasonForKeptAndOneLineForDeletable() {
        let rule = ScanSummary.make(from: [
            item(10, .delete(reason: "9 天没更新"), nil),
            item(20, .delete(reason: "12 天没更新"), nil),
            item(5, .keep(reason: "最近在用"), nil),
        ], date: Date())[.conversations]!
        XCTAssertEqual(rule.groups, [
            SummaryGroup(label: "可清理", count: 2, bytes: 30, deletable: true),
            SummaryGroup(label: "最近在用", count: 1, bytes: 5, deletable: false),
        ])
    }
}

final class ClaudeConversationTests: XCTestCase {
    let sid = "6c5b11d6-a94a-4a87-9f40-3bf1588a4d90"

    private func scan(_ h: TempHome, config: Config = Config()) -> [Candidate] {
        let env = h.env()
        return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.claudeConversations])
    }

    func testIdleSessionIncludesItsSiblingDirectory() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.file(".claude/projects/-Users-x/\(sid)/tool-results/a.txt")
        h.age(".claude", daysAgo: 9)
        let c = scan(h)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].isDelete)
        XCTAssertEqual(c[0].extraURLs.map(\.lastPathComponent), [sid])
        XCTAssertEqual(c[0].category, "7–30 天没更新")
    }

    func testSessionIdleLessThanAWeekIsKept() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.age(".claude", daysAgo: 5)
        XCTAssertEqual(scan(h).deletable, [])
    }

    func testSessionKeptWhenSiblingDirectoryIsFresh() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.file(".claude/projects/-Users-x/\(sid)/tool-results/a.txt")
        h.age(".claude", daysAgo: 9)
        h.age(".claude/projects/-Users-x/\(sid)/tool-results/a.txt", daysAgo: 1)
        XCTAssertEqual(scan(h).deletable, [])
    }

    func testOrphanSessionDirectoryIsCandidate() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid)/tool-results/a.txt")
        h.age(".claude", daysAgo: 9)
        XCTAssertEqual(scan(h).deletable.map(\.url.lastPathComponent), [sid])
    }

    func testMemoryAndIndexAreNeverCandidates() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/memory/MEMORY.md")
        h.file(".claude/projects/-Users-x/sessions-index.json")
        h.file(".claude/projects/-Users-x/notes.jsonl")
        h.age(".claude", daysAgo: 400)
        XCTAssertEqual(scan(h), [])
    }

    func testSessionMarkedWithSweepKeepIsKept() throws {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.age(".claude", daysAgo: 9)
        try PinStore(file: h.env().pinsFile).add(label: "重要方案", sessionID: sid, agent: "claude", cwd: nil, now: h.now)
        let c = scan(h)
        XCTAssertEqual(c.deletable, [])
        XCTAssertTrue(c[0].reason.contains("重要方案"))
    }

    func testCorruptPinsFileKeepsEverySession() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.age(".claude", daysAgo: 9)
        h.file("Library/Application Support/Sweep/pins.json", text: "[ broken")
        let c = scan(h)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    /// Codex 对话和 Claude 对话是两条独立的规则，开关互不影响。
    func testCodexRuleDoesNotTouchClaudeSessions() {
        let h = TempHome()
        h.file(".claude/projects/-Users-x/\(sid).jsonl")
        h.age(".claude", daysAgo: 90)
        let env = h.env()
        XCTAssertEqual(Scanner(config: Config(), env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.conversations]), [])
    }
}

final class RecordingRuleTests: XCTestCase {
    let dir = "Library/Application Support/Shandianshuo/workspace/history"

    private func scan(_ h: TempHome, config: Config = Config()) -> [Candidate] {
        let env = h.env()
        return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.recordings])
    }

    func testRecordingsOlderThanAWeekAreDeletableAndRecentOnesKept() {
        let h = TempHome()
        h.file("\(dir)/recordings/old.wav", bytes: 30_000)
        h.file("\(dir)/recordings/new.wav", bytes: 30_000)
        h.age("\(dir)/recordings/old.wav", daysAgo: 10)
        h.age("\(dir)/recordings/new.wav", daysAgo: 2)
        let c = scan(h)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), ["old.wav"])
        XCTAssertEqual(c.count, 2)
    }

    /// 转写文字的索引就在录音目录旁边，它不是录音，不能碰。
    func testTranscriptionIndexNextToTheRecordingsIsNeverACandidate() {
        let h = TempHome()
        h.file("\(dir)/transcriptions.json")
        h.file("\(dir)/recordings/old.wav")
        h.age(dir, daysAgo: 60)
        XCTAssertEqual(scan(h).map(\.url.lastPathComponent), ["old.wav"])
    }

    func testRuleCanBeDisabled() {
        let h = TempHome()
        h.file("\(dir)/recordings/old.wav")
        h.age(dir, daysAgo: 60)
        var config = Config()
        config.recordings.enabled = false
        XCTAssertEqual(scan(h, config: config), [])
    }
}

final class WorktreeRuleTests: XCTestCase {
    private var enabled: Config {
        var c = Config()
        c.workCopies.enabled = true
        return c
    }

    private func scan(_ h: TempHome, config: Config) -> [Candidate] {
        let env = h.env()
        return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.workCopies])
    }

    /// 建一个主仓库和它的一个工作树，返回工作树相对 home 的路径。
    private func worktree(_ h: TempHome, _ name: String = "wt-old") -> String {
        if !h.exists("Projects/app/.git") {
            h.file("Projects/app/README.md", text: "x")
            h.git("init", "-q", "-b", "main", in: "Projects/app")
            h.git("add", ".", in: "Projects/app")
            h.git("commit", "-q", "-m", "init", in: "Projects/app")
            h.dir("Projects/app-worktrees")
        }
        h.git("worktree", "add", "-q", "-b", name, h.path("Projects/app-worktrees/\(name)").path, in: "Projects/app")
        return "Projects/app-worktrees/\(name)"
    }

    func testCleanIdleWorktreeIsDeletable() {
        let h = TempHome()
        let wt = worktree(h)
        h.age(wt, daysAgo: 30)
        let c = scan(h, config: enabled)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), ["wt-old"])
    }

    func testAutomaticRemovalIsOffByDefault() {
        let h = TempHome()
        let wt = worktree(h)
        h.age(wt, daysAgo: 30)
        let c = scan(h, config: Config())
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testWorktreeWithUncommittedOrUntrackedChangesIsKept() {
        let h = TempHome()
        let wt = worktree(h)
        h.file("\(wt)/notes.md", text: "未提交的东西")
        h.age(wt, daysAgo: 30)
        let c = scan(h, config: enabled)
        XCTAssertEqual(c.deletable, [])
        XCTAssertTrue(c[0].reason.contains("未提交"))
    }

    func testRecentlyTouchedWorktreeIsKept() {
        let h = TempHome()
        let wt = worktree(h)
        h.age(wt, daysAgo: 5)
        XCTAssertEqual(scan(h, config: enabled).deletable, [])
    }

    /// 普通目录（不是 git 工作树）没法判断里面有没有独有的改动，永远只展示。
    func testPlainDirectoryIsNeverDeletable() {
        let h = TempHome()
        h.file("Projects/app-worktrees/copy/src/main.py")
        h.file("Projects/web-preview-build-20261011/index.html")
        h.age("Projects", daysAgo: 300)
        let c = scan(h, config: enabled)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.deletable, [])
    }

    /// 游离 HEAD 上的提交如果不属于任何分支，移除工作树后就找不回来了。
    func testDetachedWorktreeWithCommitOnNoBranchIsKept() {
        let h = TempHome()
        let wt = worktree(h)
        h.git("checkout", "-q", "--detach", in: wt)
        h.file("\(wt)/extra.txt", text: "x")
        h.git("add", ".", in: wt)
        h.git("commit", "-q", "-m", "仅在游离 HEAD 上", in: wt)
        h.age(wt, daysAgo: 30)
        XCTAssertEqual(scan(h, config: enabled).deletable, [])
    }

    func testRemovingAWorktreeAlsoClearsItsRegistrationInTheMainRepository() throws {
        let h = TempHome()
        let wt = worktree(h)
        h.age(wt, daysAgo: 30)
        let env = h.env()
        let candidates = scan(h, config: enabled)
        let report = Cleaner(env: env).run(candidates, dryRun: false)
        XCTAssertEqual(report.errors, [])
        XCTAssertFalse(h.exists(wt))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", h.path("Projects/app").path, "worktree", "list", "--porcelain"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertFalse(listing.contains("wt-old"))
        XCTAssertTrue(h.exists("Projects/app/README.md"))
    }
}

final class BigItemTests: XCTestCase {
    func testLargeItemsThatCannotBeCleanedAutomaticallyAreListedButNeverDeletable() {
        let h = TempHome()
        h.file("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 50_000)
        h.file(".codex/thread_history_1.sqlite", bytes: 20_000)
        h.age("Library", daysAgo: 400)
        let env = h.env()
        let c = Scanner(config: Config(), env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [.bigItems])
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.deletable, [])
        XCTAssertTrue(c.allSatisfy { !$0.reason.isEmpty && $0.bytes > 0 })
    }

    func testBigItemsAreNeverPartOfACleaningRun() throws {
        let h = TempHome()
        h.file(".codex/thread_history_1.sqlite", bytes: 20_000)
        _ = try Runner(env: h.env()).run(mode: .manual)
        XCTAssertTrue(h.exists(".codex/thread_history_1.sqlite"))
    }
}

final class IncludeDisabledTests: XCTestCase {
    private func home() -> TempHome {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 40)
        h.file("Projects/app/package.json", text: "{}")
        h.file("Projects/app/.next/blob.bin", bytes: 40_000)
        h.age("Projects/app/.next", daysAgo: 9)
        return h
    }

    private var codexOff: Config {
        var c = Config()
        c.conversations.enabled = false
        return c
    }

    /// 关着的规则在界面上也要显示真实数据，所以扫描可以把它们一并量出来。
    func testCanListWhatADisabledRuleWouldClean() {
        let h = home()
        let env = h.env()
        let pins = PinStore(file: env.pinsFile)
        XCTAssertEqual(Scanner(config: codexOff, env: env, pins: pins).scan(rules: [.conversations]), [])
        let all = Scanner(config: codexOff, env: env, pins: pins, includeDisabled: true).scan(rules: [.conversations])
        XCTAssertEqual(all.deletable.count, 1)
    }

    func testCleaningRunStillIgnoresDisabledRules() throws {
        let h = home()
        try codexOff.save(to: h.env().configFile)
        _ = try Runner(env: h.env()).run(mode: .manual)
        XCTAssertFalse(h.exists("Projects/app/.next"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: h.path(".codex/sessions/2026/09/01").path).count, 1)
    }

    func testTotalsCountOnlyTheRulesAskedFor() {
        let h = home()
        let env = h.env()
        let all = Scanner(config: codexOff, env: env, pins: PinStore(file: env.pinsFile), includeDisabled: true)
            .scan(rules: [.conversations, .buildCaches])
        let summary = ScanSummary.make(from: all, date: h.now)
        XCTAssertEqual(summary.deletable(in: [.buildCaches]).count, 1)
        XCTAssertEqual(summary.deletable(in: [.buildCaches, .conversations]).count, 2)
        XCTAssertEqual(summary.deletable(in: []).bytes, 0)
    }

    func testReportMarksDisabledRulesAndLeavesThemOutOfTheTotal() {
        let h = home()
        let env = h.env()
        let all = Scanner(config: codexOff, env: env, pins: PinStore(file: env.pinsFile), includeDisabled: true)
            .scan(rules: [.conversations, .buildCaches])
        let text = ReportText.scan(all, disabled: [.conversations])
        XCTAssertTrue(text.contains("Codex 对话（已关闭，不会清理）"))
        XCTAssertTrue(text.contains("合计可清理 1 项"))
    }
}

final class RuleSwitchTests: XCTestCase {
    func testReportsWhichRulesAreSwitchedOff() {
        var c = Config()
        XCTAssertEqual(c.disabledRules, [.artifacts, .workCopies])
        c.conversations.enabled = false
        c.artifacts.enabled = true
        XCTAssertEqual(c.disabledRules, [.conversations, .workCopies])
        XCTAssertTrue(c.isEnabled(.buildCaches))
        XCTAssertFalse(c.isEnabled(.conversations))
    }

    /// 「其他大户」没有开关：它既不算开着（不会清理），也不该被说成「已关闭」。
    func testBigItemsAreNeitherEnabledNorListedAsSwitchedOff() {
        let c = Config()
        XCTAssertFalse(c.isEnabled(.bigItems))
        XCTAssertFalse(c.disabledRules.contains(.bigItems))
    }
}

final class CompressedSessionTests: XCTestCase {
    /// Codex 会把旧会话压缩成 .jsonl.zst。它们仍然是对话，规则要照常适用。
    func testCompressedSessionsFollowTheSameRules() {
        let h = TempHome()
        let codex = CodexFixture(h)
        codex.session(1, daysAgo: 40, compressed: true)
        codex.session(2, daysAgo: 40, archived: true, compressed: true)
        codex.session(3, daysAgo: 300, compressed: true)
        codex.session(4, daysAgo: 300, cwd: "/p/pinned", compressed: true)
        codex.session(5, daysAgo: 40, role: "worker", compressed: true)
        codex.spawn(parent: 3, child: 5)
        codex.state(pinned: [3], pinnedProjects: ["p"], projects: ["p": ["/p/pinned"]])
        let c = scan(h)
        XCTAssertEqual(c.count, 5)
        XCTAssertEqual(find(c, 1).category, "30–90 天没更新")
        XCTAssertTrue(find(c, 1).isDelete)
        XCTAssertEqual(find(c, 2).category, "已归档")
        XCTAssertEqual(find(c, 3).category, "Codex 里 pin 的")
        XCTAssertEqual(find(c, 4).category, "在置顶项目里的")
        XCTAssertFalse(find(c, 5).isDelete)
    }

    /// 压缩文件里搜不到标记串。只要它有可能是某个还没对上号的标记所指的对话，就不能删。
    func testCompressedSessionThatMightCarryAnUnresolvedMarkIsKept() throws {
        let h = TempHome()
        let codex = CodexFixture(h)
        let store = PinStore(file: h.env().pinsFile)
        try store.add(label: "十天前标记的", sessionID: nil, agent: "codex", cwd: nil, now: h.now.addingTimeInterval(-10 * 86400))
        codex.session(1, daysAgo: 8, compressed: true)    // 标记之后还更新过：可能就是它
        codex.session(2, daysAgo: 30, compressed: true)   // 标记之前就不动了：不可能是它
        let c = scan(h)
        XCTAssertFalse(find(c, 1).isDelete)
        XCTAssertTrue(find(c, 2).isDelete)
    }

    /// 标记串一旦在未压缩的会话里找到，就把会话 ID 记进名单；之后文件被压缩也照样认得。
    func testMarkIsBoundToItsSessionSoItSurvivesCompression() throws {
        let h = TempHome()
        let codex = CodexFixture(h)
        let store = PinStore(file: h.env().pinsFile)
        let pin = try store.add(label: "调研", sessionID: nil, agent: "codex", cwd: nil, now: h.now.addingTimeInterval(-3600))
        let rel = codex.session(1, daysAgo: 0)
        h.file(rel, text: "{\"output\":\"\(pin.token)\"}")
        _ = scan(h)
        XCTAssertEqual(try store.all().first?.sessionID, CodexFixture.id(1))

        // Codex 把它压缩了，内容不再可读；时间也过去很久
        try FileManager.default.moveItem(at: h.path(rel), to: h.path(rel + ".zst"))
        h.file(rel + ".zst", bytes: 500)
        h.age(rel + ".zst", daysAgo: 60)
        h.sqlite(".codex/state_5.sqlite", "UPDATE threads SET updated_at_ms = 0;")
        let c = scan(h)
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(c[0].category, "已标记")
    }

    func testFilesThatAreNotSessionsAreStillIgnored() {
        let h = TempHome()
        _ = CodexFixture(h)
        h.file(".codex/sessions/2026/09/01/notes.jsonl.zst")
        h.file(".codex/sessions/2026/09/01/rollout-backup.tar.zst")
        h.age(".codex/sessions", daysAgo: 90)
        XCTAssertEqual(scan(h), [])
    }
}

final class ScanTotalsTests: XCTestCase {
    private func item(_ rule: RuleID, _ path: String, _ bytes: Int64, delete: Bool) -> Candidate {
        Candidate(rule: rule, url: URL(fileURLWithPath: path), root: URL(fileURLWithPath: "/"), bytes: bytes,
                  lastActivity: nil, verdict: delete ? .delete(reason: "x") : .keep(reason: "y"))
    }

    /// 工作树里的 node_modules 和缓存各有自己的规则。算总账时，工作树只算扣掉它们之后剩下的部分。
    private var sample: ScanSummary {
        ScanSummary.make(from: [
            item(.workCopies, "/p/wt", 1000, delete: false),
            item(.dependencies, "/p/wt/node_modules", 300, delete: true),
            item(.buildCaches, "/p/wt/.next", 100, delete: false),
            item(.packageCaches, "/q/cache", 50, delete: true),
            item(.bigItems, "/q/Docker.raw", 400, delete: false),
        ], date: Date())
    }

    func testScannedTotalDoesNotCountNestedItemsTwice() {
        let totals = sample.totals(disabled: [])
        XCTAssertEqual(totals.scanned, 1450)
        XCTAssertEqual(totals.cleanable, 350)
        XCTAssertEqual(totals.switchedOff, 0)
        XCTAssertEqual(totals.kept, 1100)
        XCTAssertEqual(totals.scanned, totals.cleanable + totals.switchedOff + totals.kept)
    }

    func testWhatDisabledRulesWouldCleanIsReportedSeparately() {
        let totals = sample.totals(disabled: [.dependencies])
        XCTAssertEqual(totals.cleanable, 50)
        XCTAssertEqual(totals.switchedOff, 300)
        XCTAssertEqual(totals.kept, 1100)
    }

    func testRowFiguresStayAsMeasuredForEachRule() {
        XCTAssertEqual(sample[.workCopies]?.keptBytes, 1000)
        XCTAssertEqual(sample[.dependencies]?.deletableBytes, 300)
    }

    func testSummarySavedBeforeTotalsExistedStillGivesSensibleTotals() throws {
        let h = TempHome()
        let old = #"{"date":"2026-10-13T13:35:00Z","rules":{"buildCaches":{"deletableBytes":5,"deletableCount":1,"keptBytes":2,"keptCount":1}}}"#
        let summary = try XCTUnwrap(ScanSummary.load(from: h.file("last-scan.json", text: old)))
        let totals = summary.totals(disabled: [])
        XCTAssertEqual(totals.scanned, 7)
        XCTAssertEqual(totals.cleanable, 5)
    }
}
