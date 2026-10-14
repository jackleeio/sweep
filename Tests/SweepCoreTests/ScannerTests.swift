import XCTest
@testable import SweepCore

private func scan(_ h: TempHome, _ rule: RuleID, config: Config = Config(),
                  inUse: @escaping (URL, CacheKind) -> Bool = { _, _ in false }) -> [Candidate] {
    let env = h.env(inUse: inUse)
    return Scanner(config: config, env: env, pins: PinStore(file: env.pinsFile)).scan(rules: [rule])
}

final class ConversationRuleTests: XCTestCase {
    let rollout = ".codex/sessions/2026/10/01/rollout-2026-10-01T00-00-00-01a130dd-f6c0-71a0-8d0b-2948f138ed6c.jsonl"

    func testCodexSessionIdlePastThresholdIsDeletable() {
        let h = TempHome()
        h.file(rollout)
        h.age(".codex", daysAgo: 9)
        let c = scan(h, .conversations)
        XCTAssertEqual(c.count, 1)
        XCTAssertTrue(c[0].isDelete)
    }

    func testCodexSessionUpdatedWithinThresholdIsKept() {
        let h = TempHome()
        h.file(rollout)
        h.age(".codex", daysAgo: 2)
        let c = scan(h, .conversations)
        XCTAssertEqual(c.count, 1)
        XCTAssertFalse(c[0].isDelete)
    }

    func testCodexArchivedSessionsAreCovered() {
        let h = TempHome()
        h.file(".codex/archived_sessions/rollout-2026-04-01T22-45-25-019d4981-a246-7db0-a1ed-609da5816e1a.jsonl")
        h.age(".codex", daysAgo: 30)
        XCTAssertEqual(scan(h, .conversations).deletable.count, 1)
    }

    func testCodexNonRolloutFilesAreIgnored() {
        let h = TempHome()
        h.file(".codex/sessions/2026/10/01/notes.txt")
        h.file(".codex/sessions/index.jsonl")
        h.age(".codex", daysAgo: 30)
        XCTAssertEqual(scan(h, .conversations), [])
    }

    func testCodexCandidateRootIsTheConfiguredRoot() {
        let h = TempHome()
        h.file(rollout)
        h.age(".codex", daysAgo: 9)
        XCTAssertEqual(scan(h, .conversations)[0].root.path, h.path(".codex/sessions").path)
    }

    func testSessionContainingRegisteredTokenIsKept() throws {
        let h = TempHome()
        let pin = try PinStore(file: h.env().pinsFile).add(label: "codex 调研", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        h.file(rollout, text: "{\"output\":\"已标记 \(pin.token)\"}\n")
        h.age(".codex", daysAgo: 9)
        XCTAssertEqual(scan(h, .conversations).deletable, [])
    }

    func testUnpinnedSessionBecomesDeletableAgain() throws {
        let h = TempHome()
        let store = PinStore(file: h.env().pinsFile)
        let pin = try store.add(label: "临时", sessionID: nil, agent: nil, cwd: nil, now: h.now)
        h.file(rollout, text: pin.token)
        h.age(".codex", daysAgo: 9)
        try store.remove(matching: "临时")
        XCTAssertEqual(scan(h, .conversations).deletable.count, 1)
    }

    func testCorruptPinsFileKeepsEveryConversation() {
        let h = TempHome()
        h.file(rollout)
        h.age(".codex", daysAgo: 9)
        h.file("Library/Application Support/Sweep/pins.json", text: "[ broken")
        let c = scan(h, .conversations)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testDisabledRuleYieldsNothing() {
        let h = TempHome()
        h.file(rollout)
        h.age(".codex", daysAgo: 9)
        var config = Config()
        config.conversations.enabled = false
        XCTAssertEqual(scan(h, .conversations, config: config), [])
    }
}

final class BuildCacheRuleTests: XCTestCase {
    /// 建一个带 package.json 的项目，并放入一个缓存文件。
    private func nextProject(_ h: TempHome, _ rel: String = "Projects/app", cache: String = ".next", bytes: Int = 64_000) {
        h.file("\(rel)/package.json", text: "{}")
        h.file("\(rel)/\(cache)/dev/cache/turbopack/blob.bin", bytes: bytes)
    }

    private var tinyCap: Config {
        var c = Config()
        c.buildCaches.sizeCapGB = 0.00001 // 10KB
        return c
    }

    func testIdleNextDirIsDeletable() {
        let h = TempHome()
        nextProject(h)
        h.age("Projects/app/.next", daysAgo: 4)
        let c = scan(h, .buildCaches)
        XCTAssertEqual(c.deletable.map(\.url.lastPathComponent), [".next"])
        XCTAssertEqual(c[0].root.path, h.path("Projects").path)
    }

    func testFreshNextDirUnderCapIsKept() {
        let h = TempHome()
        nextProject(h)
        let c = scan(h, .buildCaches)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testFreshNextDirOverCapIsDeletable() {
        let h = TempHome()
        nextProject(h)
        XCTAssertEqual(scan(h, .buildCaches, config: tinyCap).deletable.count, 1)
    }

    func testOverCapNextDirInUseIsKept() {
        let h = TempHome()
        nextProject(h)
        var asked: [(String, CacheKind)] = []
        let c = scan(h, .buildCaches, config: tinyCap) { dir, kind in
            asked.append((dir.lastPathComponent, kind))
            return true
        }
        XCTAssertEqual(c.deletable, [])
        XCTAssertEqual(asked.first?.0, "app")
        XCTAssertEqual(asked.first?.1, .next)
    }

    func testIdleNextDirInUseIsKept() {
        let h = TempHome()
        nextProject(h)
        h.age("Projects/app/.next", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches) { _, _ in true }.deletable, [])
    }

    func testNextVariantNamesMatch() {
        let h = TempHome()
        nextProject(h, cache: ".next-build-ads")
        nextProject(h, cache: ".next-dev-3000")
        h.age("Projects/app", daysAgo: 4)
        XCTAssertEqual(Set(scan(h, .buildCaches).deletable.map(\.url.lastPathComponent)), [".next-build-ads", ".next-dev-3000"])
    }

    func testLookalikeNamesAreIgnored() {
        let h = TempHome()
        nextProject(h, cache: ".nextcloud")
        nextProject(h, cache: "next")
        nextProject(h, cache: ".next.bak")
        h.age("Projects/app", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches), [])
    }

    func testNextDirWithoutPackageJsonIsIgnored() {
        let h = TempHome()
        h.file("Projects/notes/.next/readme.txt")
        h.age("Projects/notes", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches), [])
    }

    func testGitTrackedCacheIsKept() {
        let h = TempHome()
        nextProject(h)
        h.git("init", "-q", in: "Projects/app")
        h.git("add", "-f", ".next", in: "Projects/app")
        h.git("commit", "-q", "-m", "x", in: "Projects/app")
        h.age("Projects/app/.next", daysAgo: 30)
        let c = scan(h, .buildCaches)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testUntrackedCacheInsideGitRepoIsDeletable() {
        let h = TempHome()
        nextProject(h)
        h.git("init", "-q", in: "Projects/app")
        h.git("add", "package.json", in: "Projects/app")
        h.git("commit", "-q", "-m", "x", in: "Projects/app")
        h.age("Projects/app/.next", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches).deletable.count, 1)
    }

    func testIdleBunBuildLeftoverIsDeletable() {
        let h = TempHome()
        h.file("Projects/lab/.18bcabdfefcfebff-00000000.bun-build", bytes: 5_000)
        h.age("Projects/lab/.18bcabdfefcfebff-00000000.bun-build", daysAgo: 4)
        XCTAssertEqual(scan(h, .buildCaches).deletable.count, 1)
    }

    func testFreshBunBuildFileIsKept() {
        let h = TempHome()
        h.file("Projects/lab/.18bcabdfefcfebff-00000000.bun-build", bytes: 5_000)
        XCTAssertEqual(scan(h, .buildCaches).deletable, [])
    }

    func testIdleTauriTargetWithCacheTagIsDeletable() {
        let h = TempHome()
        h.file("Projects/desk/src-tauri/Cargo.toml")
        h.file("Projects/desk/src-tauri/target/CACHEDIR.TAG")
        h.file("Projects/desk/src-tauri/target/debug/app.bin", bytes: 9_000)
        h.age("Projects/desk/src-tauri/target", daysAgo: 6)
        XCTAssertEqual(scan(h, .buildCaches).deletable.map(\.url.lastPathComponent), ["target"])
    }

    func testTargetWithoutCacheTagIsIgnored() {
        let h = TempHome()
        h.file("Projects/desk/src-tauri/target/data.bin")
        h.age("Projects/desk", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches), [])
    }

    func testTargetOutsideSrcTauriIsIgnored() {
        let h = TempHome()
        h.file("Projects/desk/target/CACHEDIR.TAG")
        h.age("Projects/desk", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches), [])
    }

    func testDoesNotLookInsideNodeModules() {
        let h = TempHome()
        nextProject(h, "Projects/app/node_modules/dep")
        h.age("Projects/app", daysAgo: 30)
        XCTAssertEqual(scan(h, .buildCaches), [])
    }

    func testNestedProjectsAreFound() {
        let h = TempHome()
        nextProject(h, "Projects/mono/apps/web")
        h.age("Projects/mono/apps/web/.next", daysAgo: 4)
        XCTAssertEqual(scan(h, .buildCaches).deletable.count, 1)
    }

    func testProjectRootThatIsMissingYieldsNothing() {
        let h = TempHome()
        XCTAssertEqual(scan(h, .buildCaches), [])
    }
}

final class AgentTempRuleTests: XCTestCase {
    func testIdleAgentTempDirIsDeletable() {
        let h = TempHome()
        h.file(".cache/bnbot-native-layout-0albf6cg/out.bin")
        h.age(".cache/bnbot-native-layout-0albf6cg", daysAgo: 5)
        let c = scan(h, .agentTemp)
        XCTAssertEqual(c.deletable.count, 1)
        XCTAssertEqual(c[0].root.path, h.path(".cache").path)
    }

    func testFreshAgentTempDirIsKept() {
        let h = TempHome()
        h.file("Library/Caches/bnbot-codex-qa/out.bin")
        let c = scan(h, .agentTemp)
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.deletable, [])
    }

    func testGlobDoesNotMatchUnhyphenatedSibling() {
        let h = TempHome()
        h.file(".cache/bnbot/real-cache.bin")
        h.file(".cache/uv/x.bin")
        h.age(".cache", daysAgo: 30)
        XCTAssertEqual(scan(h, .agentTemp), [])
    }
}

final class PackageCacheRuleTests: XCTestCase {
    func testUnderCapKeepsAll() {
        let h = TempHome()
        h.file("Library/Caches/Yarn/v6/a.tgz", bytes: 50_000)
        h.file(".npm/_cacache/content/b", bytes: 50_000)
        let c = scan(h, .packageCaches)
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c.deletable, [])
    }

    func testOverCapMarksAllDeletable() {
        let h = TempHome()
        h.file("Library/Caches/Yarn/v6/a.tgz", bytes: 50_000)
        h.file(".npm/_cacache/content/b", bytes: 50_000)
        var config = Config()
        config.packageCaches.totalCapGB = 0.00005 // 50KB，两项合计超过
        XCTAssertEqual(scan(h, .packageCaches, config: config).deletable.count, 2)
    }

    func testCandidatesMustSitAtLeastTwoLevelsBelowHome() {
        let h = TempHome()
        h.file("Library/Caches/Yarn/v6/a.tgz")
        let c = scan(h, .packageCaches)
        XCTAssertEqual(c[0].root.path, h.url.path)
        XCTAssertEqual(c[0].minDepth, 2)
    }
}

final class ArtifactRuleTests: XCTestCase {
    func testDisabledByDefault() {
        let h = TempHome()
        h.file(".codex/visualizations/2026/09/a.mp4")
        h.age(".codex", daysAgo: 90)
        XCTAssertEqual(scan(h, .artifacts), [])
    }

    func testEnabledMarksOnlyFilesOlderThanItsOwnThreshold() {
        let h = TempHome()
        h.file(".codex/visualizations/2026/09/old.mp4")
        h.file(".codex/visualizations/2026/10/recent.mp4")
        h.age(".codex", daysAgo: 40)
        h.age(".codex/visualizations/2026/10/recent.mp4", daysAgo: 10)
        var config = Config()
        config.artifacts.enabled = true
        XCTAssertEqual(scan(h, .artifacts, config: config).deletable.map(\.url.lastPathComponent), ["old.mp4"])
    }
}

final class WorkCopyRuleTests: XCTestCase {
    func testWorkCopiesAreListedButNeverDeletable() {
        let h = TempHome()
        h.file("Projects/api-worktrees/wt-20260903-x/src/main.py", bytes: 20_000)
        h.file("Projects/web-hidden-office-build-20261011/index.html", bytes: 20_000)
        h.age("Projects", daysAgo: 300)
        let c = scan(h, .workCopies)
        XCTAssertEqual(Set(c.map(\.url.lastPathComponent)), ["wt-20260903-x", "web-hidden-office-build-20261011"])
        XCTAssertEqual(c.deletable, [])
        XCTAssertGreaterThan(c[0].bytes, 0)
    }
}
