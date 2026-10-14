import XCTest
@testable import SweepCore

final class CommandLineLinkTests: XCTestCase {
    private let fm = FileManager.default

    private func app(_ h: TempHome, _ name: String) -> URL {
        h.file("\(name)/Sweep.app/Contents/Helpers/sweep", text: "#!/bin/sh")
    }

    func testCreatesTheLinkAndItsDirectoryWhenNothingIsThere() throws {
        let h = TempHome()
        let target = app(h, "Applications")
        let link = h.path(".local/bin/sweep")
        XCTAssertEqual(CommandLineLink.install(target: target, at: link), .created)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    func testLeavesALinkThatAlreadyPointsHereAlone() throws {
        let h = TempHome()
        let target = app(h, "Applications")
        let link = h.path(".local/bin/sweep")
        _ = CommandLineLink.install(target: target, at: link)
        XCTAssertEqual(CommandLineLink.install(target: target, at: link), .alreadyLinked)
    }

    /// 换了安装位置（比如从下载目录拖进了应用程序）时，把旧链接改指新位置。
    func testRepointsALinkLeftByAnotherCopyOfSweep() throws {
        let h = TempHome()
        let old = app(h, "Downloads")
        let target = app(h, "Applications")
        let link = h.path(".local/bin/sweep")
        h.dir(".local/bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: old)
        XCTAssertEqual(CommandLineLink.install(target: target, at: link), .updated)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    /// 从源码安装的命令行是一个普通文件，绝不能被覆盖。
    func testNeverReplacesARegularFile() throws {
        let h = TempHome()
        let target = app(h, "Applications")
        let link = h.file(".local/bin/sweep", text: "source-built binary")
        XCTAssertEqual(CommandLineLink.install(target: target, at: link), .keptExistingFile)
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "source-built binary")
    }

    func testNeverReplacesALinkToSomethingElse() throws {
        let h = TempHome()
        let target = app(h, "Applications")
        let other = h.file("tools/sweep", text: "another tool")
        let link = h.path(".local/bin/sweep")
        h.dir(".local/bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertEqual(CommandLineLink.install(target: target, at: link), .keptForeignLink)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), other.path)
    }
}
