import XCTest
@testable import SweepCore

/// 进程表是注入的：测试里手工搭进程树，观察记录和结束动作都不碰真实进程。
final class FakeProcessSystem: ProcessSystem {
    var current: ProcessSnapshot?
    var ended: [ProcessEntry] = []
    init(_ snapshot: ProcessSnapshot?) { current = snapshot }
    func snapshot() -> ProcessSnapshot? { current }
    func end(_ processes: [ProcessEntry]) -> [ProcessEntry] {
        ended += processes
        return processes
    }
}

private let me: UInt32 = 501

extension Config.Processes {
    /// 总开关打开，其余取默认值。
    static var allOn: Config.Processes {
        var config = Config.Processes()
        config.enabled = true
        return config
    }
}

private func proc(_ pid: Int32, parent: Int32 = 1, _ command: String, name: String? = nil, exe: String? = nil,
                  cpu: Double = 0, mb: Int64 = 100, tty: String? = nil, uid: UInt32 = me) -> ProcessEntry {
    let args = command.split(separator: " ").map(String.init)
    let executable = exe ?? args.first ?? ""
    return ProcessEntry(pid: pid, ppid: parent, uid: uid, name: name ?? URL(fileURLWithPath: executable).lastPathComponent,
                        executable: executable, arguments: args, startMicros: Int64(pid) * 1000, cpuSeconds: cpu,
                        memory: mb << 20, tty: tty)
}

private func snapshot(_ processes: [ProcessEntry], launchd: Set<Int32>? = [], pressure: Bool = false,
                      ttyInput: [String: Date] = [:], selfPID: Int32 = 99_999) -> ProcessSnapshot {
    ProcessSnapshot(processes: processes, userID: me, selfPID: selfPID, launchdPIDs: launchd,
                    underMemoryPressure: pressure, ttyInput: ttyInput)
}

private let codexApp = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"

final class ProcessSignatureTests: XCTestCase {
    func testRecognisesMCPServers() {
        for command in ["node /x/rea-agents/scripts/rea.mjs mcp", "/x/.venv/bin/python /x/.venv/bin/blender-mcp",
                        "npm exec @modelcontextprotocol/server-github", "node /x/.bin/mcp-server-github",
                        "node /x/chrome-devtools-mcp/index.js"] {
            XCTAssertTrue(ProcessSignature.isMCP(command), command)
        }
        for command in ["node /opt/homebrew/bin/ocx start --port 10100", "/usr/bin/vim mcpfile.txt", "node /x/smcp.js"] {
            XCTAssertFalse(ProcessSignature.isMCP(command), command)
        }
    }

    func testRecognisesDevServersBuildsAndTests() {
        for command in ["next-server (v15.5.21)", "node /p/node_modules/.bin/next build", "node /p/node_modules/.bin/next dev --turbopack",
                        "npm run dev:agent", "npm run build", "bun test", "sh -c timeout 3600 bun test > /tmp/x.log",
                        "node /p/node_modules/.bin/tsc --noEmit", "node /p/node_modules/.bin/vite", "pnpm dev"] {
            XCTAssertTrue(ProcessSignature.isDevTool(command), command)
        }
        for command in ["node /opt/homebrew/bin/bnbot serve", "node /x/claude-desktop-sync/sync.mjs daemon",
                        "node /p/node_modules/.bin/next start", "node /x/vite-plugin/index.js", "/usr/bin/tscope"] {
            XCTAssertFalse(ProcessSignature.isDevTool(command), command)
        }
    }

    func testRecognisesAgentCLIs() {
        XCTAssertTrue(ProcessSignature.isAgent(proc(1, "/Users/a/.local/share/claude/versions/2.1.314 --x", name: "2.1.314")))
        XCTAssertTrue(ProcessSignature.isAgent(proc(1, "/opt/grok/grok-1.0.70-macos-aarch64")))
        XCTAssertTrue(ProcessSignature.isAgent(proc(1, codexApp)))
        XCTAssertFalse(ProcessSignature.isAgent(proc(1, "/bin/zsh")))
        XCTAssertFalse(ProcessSignature.isAgent(proc(1, "node /x/server.js")))
    }
}

final class ProcessWatchTests: XCTestCase {
    func testFirstSightingCountsAsActiveNow() {
        let t0 = Date()
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x")]), now: t0)
        XCTAssertEqual(watch.seen["10@10000"]?.lastActive, t0)
    }

    func testCPUGrowthBelowThresholdKeepsLastActive() {
        let t0 = Date()
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x", cpu: 5)]), now: t0)
        // 10 分钟只多用了 1 秒 CPU（不到 1%），不算活动
        watch.observe(snapshot([proc(10, "x", cpu: 6)]), now: t0 + 600)
        XCTAssertEqual(watch.seen["10@10000"]?.lastActive, t0)
        // 再 10 分钟多用了 30 秒，算活动
        watch.observe(snapshot([proc(10, "x", cpu: 36)]), now: t0 + 1200)
        XCTAssertEqual(watch.seen["10@10000"]?.lastActive, t0 + 1200)
    }

    func testBusyNeedsMoreCPUThanActive() {
        let t0 = Date()
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x", cpu: 0)]), now: t0)
        // 2% 左右：算活动，但不算忙（终端界面空转大概就是这个量）
        watch.observe(snapshot([proc(10, "x", cpu: 12)]), now: t0 + 600)
        XCTAssertEqual(watch.seen["10@10000"]?.lastActive, t0 + 600)
        XCTAssertEqual(watch.seen["10@10000"]?.lastBusy, t0)
    }

    func testLongGapDoesNotDiluteActivity() {
        let t0 = Date()
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x", cpu: 0)]), now: t0)
        // 睡眠 10 小时后醒来：期间用了 10 秒 CPU，按 10 分钟的窗口算仍是活动
        watch.observe(snapshot([proc(10, "x", cpu: 10)]), now: t0 + 36_000)
        XCTAssertEqual(watch.seen["10@10000"]?.lastActive, t0 + 36_000)
    }

    func testReusedPIDWithDifferentStartIsANewProcess() {
        let t0 = Date()
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x")]), now: t0)
        var reused = proc(10, "y")
        reused.startMicros = 777
        watch.observe(snapshot([reused]), now: t0 + 7200)
        XCTAssertNil(watch.seen["10@10000"])
        XCTAssertEqual(watch.seen["10@777"]?.lastActive, t0 + 7200)
    }

    func testTerminalInputCountsAsActivity() {
        let t0 = Date()
        var watch = ProcessWatch()
        let session = proc(10, "/opt/grok/grok-1.0.70", tty: "ttys001")
        watch.observe(snapshot([session]), now: t0)
        watch.observe(snapshot([session], ttyInput: ["ttys001": t0 + 300]), now: t0 + 600)
        XCTAssertEqual(watch.seen["10@10000"]?.lastBusy, t0 + 600)
    }

    func testOtherUsersProcessesAreNotRecorded() {
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "x", uid: 0)]), now: Date())
        XCTAssertTrue(watch.seen.isEmpty)
    }

    func testCorruptFileStartsFresh() throws {
        let h = TempHome()
        let file = h.file("processes.json", text: "{not json")
        XCTAssertEqual(ProcessWatch.load(from: file), ProcessWatch())
    }
}

final class ProcessPlannerTests: XCTestCase {
    private let t0 = Date()

    /// 先看一次，再隔 hours 小时看一次（CPU 不变），返回第二次的计划。
    private func plan(_ processes: [ProcessEntry], after hours: Double, config: Config.Processes = .allOn,
                      launchd: Set<Int32>? = [], pressure: Bool = false, ttyInput: [String: Date] = [:],
                      selfPID: Int32 = 99_999, claudeActivity: @escaping (String, String) -> Date? = { _, _ in nil })
        -> [ProcessCandidate] {
        var watch = ProcessWatch()
        watch.observe(snapshot(processes, launchd: launchd), now: t0)
        let later = t0 + hours * 3600
        let snap = snapshot(processes, launchd: launchd, pressure: pressure, ttyInput: ttyInput, selfPID: selfPID)
        watch.observe(snap, now: later)
        return ProcessPlanner(config: config, now: later, claudeActivity: claudeActivity).plan(snap, watch: watch)
    }

    private func ending(_ candidates: [ProcessCandidate]) -> [Int32] { candidates.filter(\.isEnd).map(\.root.pid).sorted() }

    // MARK: 孤儿残留

    func testIdleOrphanMCPServerIsEnded() {
        let c = plan([proc(10, "node /x/rea.mjs mcp")], after: 2)
        XCTAssertEqual(c.first?.rule, .orphans)
        XCTAssertEqual(ending(c), [10])
    }

    func testOrphanIsKeptUntilIdleLongEnough() {
        let c = plan([proc(10, "node /x/rea.mjs mcp")], after: 0.5)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(ending(c), [])
    }

    func testFirstSightingIsNeverEnded() {
        let p = [proc(10, "node /x/rea.mjs mcp")]
        var watch = ProcessWatch()
        let snap = snapshot(p)
        watch.observe(snap, now: t0)
        XCTAssertEqual(ending(ProcessPlanner(config: .allOn, now: t0).plan(snap, watch: watch)), [])
    }

    func testOrphanWithoutAgentSignatureIsIgnored() {
        // 手动起的常驻服务：孤儿、很老、不占 CPU，但不像 agent 留下的
        let c = plan([proc(10, "node /opt/homebrew/bin/ocx start --port 10100"),
                      proc(11, "node /opt/homebrew/bin/bnbot serve"),
                      proc(12, "node /x/claude-desktop-sync/sync.mjs daemon")], after: 400)
        XCTAssertTrue(c.isEmpty)
    }

    func testOrphanLeftInTempDirectoryIsEnded() {
        let c = plan([proc(10, "/opt/homebrew/bin/bun /var/folders/p1/x/T/bnbot-mobile-timeout-1/hung-node --version")], after: 2)
        XCTAssertEqual(ending(c), [10])
    }

    func testOrphanTreeIsEndedTogetherWhenAChildMatches() {
        let c = plan([proc(10, "sh -c timeout 3600 run-tests"), proc(11, parent: 10, "timeout 3600 bun test"),
                      proc(12, parent: 11, "bun test")], after: 4)
        XCTAssertEqual(ending(c), [10])
        XCTAssertEqual(c.first?.members.map(\.pid), [10, 11, 12])
    }

    func testBusyOrphanIsKept() {
        let t1 = t0 + 2 * 3600
        var watch = ProcessWatch()
        watch.observe(snapshot([proc(10, "bun test", cpu: 0)]), now: t0)
        let snap = snapshot([proc(10, "bun test", cpu: 3000)])
        watch.observe(snap, now: t1)
        XCTAssertEqual(ending(ProcessPlanner(config: .allOn, now: t1).plan(snap, watch: watch)), [])
    }

    func testAppWithMCPChildIsNotAnOrphan() {
        // 应用的父进程本来就是 launchd；它带着 MCP 子进程，不能因此被当成孤儿
        let c = plan([proc(10, "/Applications/Claude.app/Contents/MacOS/Claude"),
                      proc(11, parent: 10, "node /x/rea.mjs mcp"),
                      proc(20, "/bin/zsh -l", tty: "ttys001"),
                      proc(21, parent: 20, "node /x/rea.mjs mcp", tty: "ttys001")], after: 5)
        XCTAssertTrue(c.isEmpty, "\(c.map(\.root.pid))")
    }

    func testBundledHelperUnderVarFoldersIsNotAnOrphan() {
        // 微信读书的小组件扩展就住在 /var/folders/…/X/ 下，父进程是 launchd，跑了几百小时
        let widget = "/private/var/folders/p1/abc/X/C0166498/d/Wrapper/WeRead.app/PlugIns/ModernWidgetExtension.appex/ModernWidgetExtension"
        XCTAssertTrue(plan([proc(10, widget + " -BSServiceDomains x")], after: 400).isEmpty)
        XCTAssertTrue(plan([proc(11, "/private/var/folders/p1/abc/X/some-helper --serve")], after: 400).isEmpty)
    }

    func testOrphanDevServerWaitsAsLongAsOtherDevServers() {
        let tree = [proc(10, "bun run dev"), proc(11, parent: 10, "node /p/node_modules/.bin/electron .")]
        XCTAssertEqual(ending(plan(tree, after: 2)), [])
        XCTAssertEqual(ending(plan(tree, after: 4)), [10])
    }

    private let session = "508529a3-6c3e-4051-a5b2-0123456789ab"
    private var monitor: ProcessEntry {
        proc(10, "tail -n +1 -F /private/tmp/claude-501/-Users-a-Projects-bnbot/\(session)/tasks/b1.output")
    }

    func testLeftoverOfActiveClaudeSessionIsKept() {
        var asked: [String] = []
        let c = plan([monitor], after: 2, claudeActivity: { project, id in
            asked.append("\(project)/\(id)")
            return self.t0 + 1.5 * 3600
        })
        XCTAssertEqual(asked.first, "-Users-a-Projects-bnbot/\(session)")
        XCTAssertEqual(ending(c), [])
        XCTAssertEqual(c.first?.reason.contains("Claude 会话"), true)
    }

    func testLeftoverOfQuietClaudeSessionIsEnded() {
        XCTAssertEqual(ending(plan([monitor], after: 2, claudeActivity: { _, _ in self.t0 - 10 * 86400 })), [10])
        // 会话记录已经没了：会话早就不在了
        XCTAssertEqual(ending(plan([monitor], after: 2, claudeActivity: { _, _ in nil })), [10])
    }

    func testLaunchdManagedServiceIsNeverAnOrphanCandidate() {
        XCTAssertTrue(plan([proc(10, "node /x/rea.mjs mcp")], after: 5, launchd: [10]).isEmpty)
    }

    func testReaperLooksUpClaudeTranscripts() throws {
        let h = TempHome()
        h.file(".claude/projects/-Users-a-Projects-bnbot/\(session).jsonl", text: "{}")
        let fake = FakeProcessSystem(snapshot([monitor]))
        var env = h.env()
        env.processSystem = fake
        _ = ProcessReaper(env: env).run(.allOn, end: true)
        env.now = h.now + 2 * 3600
        let result = ProcessReaper(env: env).run(.allOn, end: true)
        XCTAssertTrue(fake.ended.isEmpty, "会话记录刚更新过，tail 属于活着的会话")
        XCTAssertEqual(result.candidates.first?.reason.contains("Claude 会话"), true)
    }

    func testUnknownLaunchdListSkipsOrphanRule() {
        let c = plan([proc(10, "node /x/rea.mjs mcp")], after: 5, launchd: nil)
        XCTAssertEqual(ending(c), [])
        XCTAssertEqual(c.first?.reason.contains("launchd"), true)
    }

    func testOrphanWithTerminalIsOnlyEndedWhenItIsAnMCPServer() {
        let c = plan([proc(10, "node /p/node_modules/.bin/next dev", tty: "ttys001"),
                      proc(11, "node /x/rea.mjs mcp", tty: "ttys001")], after: 5)
        XCTAssertEqual(ending(c), [11])
    }

    // MARK: Codex 工具进程

    private func codexTree() -> [ProcessEntry] {
        [proc(1000, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
         proc(1001, parent: 1000, codexApp + " app-server"),
         proc(1002, parent: 1001, "node /x/rea.mjs mcp"),
         proc(1003, parent: 1001, "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node ./server.mjs",
              exe: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node"),
         proc(1004, parent: 1001, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex-code-mode-host")]
    }

    func testIdleCodexToolProcessesAreEnded() {
        let c = plan(codexTree(), after: 4)
        XCTAssertEqual(ending(c), [1002, 1003])
        XCTAssertTrue(c.allSatisfy { $0.rule == .codexTools })
    }

    func testCodexToolsAreKeptBeforeThreshold() {
        XCTAssertEqual(ending(plan(codexTree(), after: 2)), [])
    }

    func testCodexToolWithActiveDescendantIsKept() {
        let t1 = t0 + 4 * 3600
        let browser = proc(1010, parent: 1003, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpu: 0)
        var watch = ProcessWatch()
        watch.observe(snapshot(codexTree() + [browser]), now: t0)
        var busy = browser
        busy.cpuSeconds = 500
        let snap = snapshot(codexTree() + [busy])
        watch.observe(snap, now: t1)
        XCTAssertEqual(ending(ProcessPlanner(config: .allOn, now: t1).plan(snap, watch: watch)), [1002])
    }

    func testTerminalCodexSessionIsNotTreatedAsTheApp() {
        let c = plan([proc(2000, "/opt/homebrew/bin/codex", tty: "ttys003"),
                      proc(2001, parent: 2000, "node /x/rea.mjs mcp", tty: "ttys003")], after: 4)
        XCTAssertFalse(c.contains { $0.rule == .codexTools })
    }

    // MARK: agent 遗留的 dev server

    func testIdleDevServerStartedByAgentIsEndedFromItsTopmostProcess() {
        let tree = codexTree() + [proc(1020, parent: 1001, "npm run dev:agent"),
                                  proc(1021, parent: 1020, "node /p/node_modules/.bin/next dev --port 3001"),
                                  proc(1022, parent: 1021, "next-server (v15.5.21)", mb: 7000)]
        let c = plan(tree, after: 4).filter { $0.rule == .devServers }
        XCTAssertEqual(c.map(\.root.pid), [1020])
        XCTAssertEqual(c.first?.memory, (100 + 100 + 7000) << 20)
        XCTAssertEqual(c.first?.isEnd, true)
    }

    func testDevServerStartedByUserIsIgnored() {
        let c = plan([proc(3000, "/Applications/Ghostty.app/Contents/MacOS/ghostty"),
                      proc(3001, parent: 3000, "/bin/zsh", tty: "ttys004"),
                      proc(3002, parent: 3001, "npm run dev", tty: "ttys004")], after: 10)
        XCTAssertTrue(c.isEmpty)
    }

    /// 一直在用、但内存涨过上限的 dev server（Turbopack 常驻会一直涨）。
    private func busyDevServer(mb: Int64, capGB: Double) -> [ProcessCandidate] {
        let t1 = t0 + 600
        var config = Config.Processes.allOn
        config.devServerMemoryCapGB = capGB
        let tree = { (cpu: Double) in
            self.codexTree() + [proc(1020, parent: 1001, "npm run dev:agent"),
                                proc(1022, parent: 1020, "next-server (v15.5.21)", cpu: cpu, mb: mb)]
        }
        var watch = ProcessWatch()
        watch.observe(snapshot(tree(0)), now: t0)
        let snap = snapshot(tree(300))
        watch.observe(snap, now: t1)
        return ProcessPlanner(config: config, now: t1).plan(snap, watch: watch).filter { $0.rule == .devServers }
    }

    func testBusyDevServerOverMemoryCapIsEnded() {
        let c = busyDevServer(mb: 8000, capGB: 4)
        XCTAssertEqual(ending(c), [1020])
        XCTAssertEqual(c.first?.reason.contains("内存"), true)
    }

    func testBusyDevServerUnderMemoryCapIsKept() {
        XCTAssertEqual(ending(busyDevServer(mb: 2000, capGB: 4)), [])
    }

    func testMemoryCapIsOffByDefault() {
        XCTAssertEqual(Config.Processes().devServerMemoryCapGB, 0)
        XCTAssertEqual(ending(busyDevServer(mb: 30_000, capGB: 0)), [])
    }

    func testDevServerUnderClaudeCodeCounts() {
        let c = plan([proc(4000, "/Users/a/.local/share/claude/versions/2.1.314", name: "2.1.314", tty: "ttys005"),
                      proc(4001, parent: 4000, "/bin/zsh -c npm run build"),
                      proc(4002, parent: 4001, "npm run build")], after: 4, ttyInput: [:])
        XCTAssertEqual(c.filter { $0.rule == .devServers }.map(\.root.pid), [4001])
    }

    // MARK: 闲置的终端会话

    private func grokSession() -> [ProcessEntry] {
        [proc(5000, "/bin/zsh", tty: "ttys002"),
         proc(5001, parent: 5000, "/opt/grok/grok-1.0.70-macos-aarch64", tty: "ttys002"),
         proc(5002, parent: 5001, "node /x/rea.mjs mcp", tty: "ttys002")]
    }

    func testIdleSessionIsEndedUnderMemoryPressure() {
        let c = plan(grokSession(), after: 30, pressure: true)
        XCTAssertEqual(c.map(\.rule), [.idleSessions])
        XCTAssertEqual(ending(c), [5001])
        XCTAssertEqual(c.first?.members.map(\.pid), [5001, 5002])
    }

    func testIdleSessionIsKeptWithoutMemoryPressure() {
        let c = plan(grokSession(), after: 30, pressure: false)
        XCTAssertEqual(ending(c), [])
        XCTAssertEqual(c.first?.reason.contains("内存"), true)
    }

    func testRecentTerminalInputKeepsSession() {
        let c = plan(grokSession(), after: 30, pressure: true, ttyInput: ["ttys002": t0 + 29 * 3600])
        XCTAssertEqual(ending(c), [])
    }

    // MARK: 保护

    func testDisabledRuleProducesNoCandidates() {
        var config = Config.Processes.allOn
        config.orphans = false
        XCTAssertTrue(plan([proc(10, "node /x/rea.mjs mcp")], after: 5, config: config).isEmpty)
    }

    func testExcludedCommandIsKept() {
        var config = Config.Processes.allOn
        config.excludes = ["rea.mjs"]
        let c = plan([proc(10, "node /x/rea.mjs mcp")], after: 5, config: config)
        XCTAssertEqual(ending(c), [])
    }

    func testTreeContainingSweepOrItsAncestorsIsKept() {
        let c = plan([proc(10, "sh -c bun test"), proc(11, parent: 10, "/Users/a/.local/bin/sweep procs --end")],
                     after: 5, selfPID: 11)
        XCTAssertEqual(ending(c), [])
    }

    func testTreeWithAnotherUsersProcessIsKept() {
        let c = plan([proc(10, "node /x/rea.mjs mcp"), proc(11, parent: 10, "/usr/sbin/helper", uid: 0)], after: 5)
        XCTAssertEqual(ending(c), [])
    }

    func testNestedCandidateIsDroppedInFavourOfTheOuterOne() {
        // 闲置会话里的 dev server：会话整个结束，不再单独列 dev server
        let tree = grokSession() + [proc(5003, parent: 5001, "npm run dev", tty: "ttys002")]
        let c = plan(tree, after: 30, pressure: true)
        XCTAssertEqual(c.map(\.root.pid), [5001])
    }
}

final class ProcessReaperTests: XCTestCase {
    private func env(_ h: TempHome, _ system: ProcessSystem, now: Date) -> Env {
        var env = h.env()
        env.now = now
        env.processSystem = system
        return env
    }

    func testEndsIdleCandidatesAndLogs() throws {
        let h = TempHome()
        let fake = FakeProcessSystem(snapshot([proc(10, "node /x/rea.mjs mcp")]))
        _ = ProcessReaper(env: env(h, fake, now: h.now)).run(.allOn, end: true)
        XCTAssertTrue(fake.ended.isEmpty, "第一次只观察")

        let result = ProcessReaper(env: env(h, fake, now: h.now + 7200)).run(.allOn, end: true)
        XCTAssertEqual(fake.ended.map(\.pid), [10])
        XCTAssertEqual(result.ended.map(\.root.pid), [10])
        let log = try String(contentsOf: h.env().logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("END orphans"), log)
        XCTAssertTrue(log.contains("rea.mjs"), log)
    }

    func testListingDoesNotEnd() {
        let h = TempHome()
        let fake = FakeProcessSystem(snapshot([proc(10, "node /x/rea.mjs mcp")]))
        _ = ProcessReaper(env: env(h, fake, now: h.now)).run(.allOn, end: false)
        let result = ProcessReaper(env: env(h, fake, now: h.now + 7200)).run(.allOn, end: false)
        XCTAssertTrue(fake.ended.isEmpty)
        XCTAssertEqual(result.candidates.filter(\.isEnd).count, 1)
    }

    func testUnreadableProcessTableEndsNothing() {
        let h = TempHome()
        let fake = FakeProcessSystem(nil)
        let result = ProcessReaper(env: env(h, fake, now: h.now)).run(.allOn, end: true)
        XCTAssertTrue(fake.ended.isEmpty)
        XCTAssertNotNil(result.error)
    }

    func testSchedulerEndsProcessesOnlyWhenEnabled() throws {
        let h = TempHome()
        let fake = FakeProcessSystem(snapshot([proc(10, "node /x/rea.mjs mcp")]))
        var config = Config()
        try config.save(to: h.env().configFile)
        _ = try Runner(env: env(h, fake, now: h.now)).tick()
        _ = try Runner(env: env(h, fake, now: h.now + 7200)).tick()
        XCTAssertTrue(fake.ended.isEmpty, "默认关闭")

        config.processes.enabled = true
        try config.save(to: h.env().configFile)
        _ = try Runner(env: env(h, fake, now: h.now + 7800)).tick()
        _ = try Runner(env: env(h, fake, now: h.now + 15_000)).tick()
        XCTAssertEqual(fake.ended.map(\.pid), [10])
    }

    func testProcessCleanupDoesNotNeedDiskCleanupToBeArmed() throws {
        let h = TempHome()
        let fake = FakeProcessSystem(snapshot([proc(10, "node /x/rea.mjs mcp")]))
        var config = Config()
        config.processes.enabled = true
        try config.save(to: h.env().configFile)
        _ = try Runner(env: env(h, fake, now: h.now)).tick()
        let outcome = try Runner(env: env(h, fake, now: h.now + 7200)).tick()
        XCTAssertEqual(outcome.processes?.ended.count, 1)
        XCTAssertFalse(SweepState.load(from: h.env().stateFile).armed)
    }

    func testOldConfigWithoutProcessSectionKeepsItOff() throws {
        let h = TempHome()
        let file = h.file("c.json", text: #"{"idleDays": 3}"#)
        let config = try Config.load(from: file)
        XCTAssertFalse(config.processes.enabled)
        XCTAssertTrue(config.processes.orphans)
    }
}

/// 真实进程表和真实的结束动作，只针对测试自己起的子进程。
final class LiveProcessSystemTests: XCTestCase {
    private func spawnSleeper() throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        try p.run()
        return p
    }

    func testSnapshotIncludesThisProcessWithArguments() throws {
        let snap = try XCTUnwrap(LiveProcessSystem().snapshot())
        let mine = try XCTUnwrap(snap.processes.first { $0.pid == getpid() })
        XCTAssertEqual(mine.uid, getuid())
        XCTAssertFalse(mine.arguments.isEmpty)
        XCTAssertGreaterThan(mine.memory, 0)
        XCTAssertGreaterThan(mine.cpuSeconds, 0)
        XCTAssertEqual(snap.selfPID, getpid())
    }

    func testEndsAChildProcess() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        let system = LiveProcessSystem()
        let entry = try XCTUnwrap(system.snapshot()?.processes.first { $0.pid == child.processIdentifier })
        XCTAssertEqual(entry.arguments, ["/bin/sleep", "30"])
        XCTAssertEqual(entry.ppid, getpid())
        XCTAssertEqual(system.end([entry]).map(\.pid), [child.processIdentifier])
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
    }

    func testParsesLaunchdServiceList() {
        let output = "gui/501 = {\n\ttype = login\n\tservices = {\n\t\t   94277    -15 \tcom.jacklee.claude-desktop-sync\n"
            + "\t\t       0      0 \tcom.jacklee.sweep.daily\n\t\t   34215      - \tai.bnbot.v3-preview\n\t}\n\tother = {\n\t\t  777 x\n\t}\n}"
        XCTAssertEqual(LiveProcessSystem.parseLaunchdServices(output), [94277, 34215])
    }

    func testReadsLaunchdServicesOfThisUser() throws {
        // 跑测试的终端可能不在 gui 域里，读不到时跳过
        guard let pids = LiveProcessSystem.launchdPIDs(uid: getuid()) else { throw XCTSkip("读不到 gui 域") }
        XCTAssertFalse(pids.isEmpty)
    }

    func testRefusesWhenStartTimeDoesNotMatch() throws {
        let child = try spawnSleeper()
        defer { child.terminate() }
        let system = LiveProcessSystem()
        var entry = try XCTUnwrap(system.snapshot()?.processes.first { $0.pid == child.processIdentifier })
        entry.startMicros += 1
        XCTAssertTrue(system.end([entry]).isEmpty)
        XCTAssertTrue(child.isRunning)
    }
}
