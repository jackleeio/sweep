import XCTest
@testable import SweepCore

final class StorageReportTests: XCTestCase {
    private let gb = Int64(1_000_000_000)

    private func home() -> TempHome {
        let h = TempHome()
        h.file("Projects/app/src/main.swift", bytes: 300_000)
        h.file("Projects/app/.next/blob.bin", bytes: 200_000)
        h.file(".codex/sessions/a.jsonl", bytes: 100_000)
        h.file("Library/Caches/com.example/data.bin", bytes: 50_000)
        h.file("Library/Application Support/Example/db.sqlite", bytes: 80_000)
        h.file("Library/Containers/com.example/data.bin", bytes: 40_000)
        h.file("Library/Logs/x.log", bytes: 10_000)
        h.file("Pictures/photo.jpg", bytes: 70_000)
        h.file("Downloads/setup.dmg", bytes: 60_000)
        return h
    }

    private func report(_ h: TempHome, candidates: [Candidate] = [], used: Int64 = 10_000_000) -> StorageReport {
        let volumes = VolumeUsage(total: 20_000_000, dataUsed: used, system: 1_000, preboot: 2_000, recovery: 3_000, vm: 4_000)
        return StorageReport.build(env: h.env(), candidates: candidates, volumes: volumes, applications: [], systemPaths: [], tempDirs: [])
    }

    private func area(_ r: StorageReport, _ id: String) -> StorageArea { r.areas.first { $0.id == id }! }

    func testEveryPartOfTheHomeFolderLandsInExactlyOneArea() {
        let h = home()
        let r = report(h)
        XCTAssertGreaterThanOrEqual(area(r, "projects").bytes, 500_000)
        XCTAssertGreaterThanOrEqual(area(r, "agentData").bytes, 100_000)
        XCTAssertGreaterThanOrEqual(area(r, "caches").bytes, 50_000)
        XCTAssertGreaterThanOrEqual(area(r, "appSupport").bytes, 80_000)
        XCTAssertGreaterThanOrEqual(area(r, "containers").bytes, 40_000)
        XCTAssertGreaterThanOrEqual(area(r, "libraryOther").bytes, 10_000)
        XCTAssertGreaterThanOrEqual(area(r, "personal").bytes, 130_000)
        XCTAssertLessThan(area(r, "personal").bytes, 200_000)
    }

    /// 读不到的部分 = 已用空间 − 能量到的各块。系统卷单独算。
    func testWhatCannotBeMeasuredIsShownAsProtected() {
        let h = home()
        let r = report(h)
        let measured = r.areas.filter { $0.id != "protected" && $0.id != "system" }.reduce(Int64(0)) { $0 + $1.bytes }
        XCTAssertEqual(area(r, "protected").bytes, 10_000_000 - measured)
        XCTAssertEqual(area(r, "system").bytes, 1_000 + 2_000 + 3_000 + 4_000)
        XCTAssertEqual(r.used, 10_000_000 + 10_000)
    }

    func testCleanableSpaceIsAttributedToTheAreaThatHoldsIt() {
        let h = home()
        let next = Candidate(rule: .buildCaches, url: h.path("Projects/app/.next"), root: h.path("Projects"),
                             bytes: 200_000, lastActivity: nil, verdict: .delete(reason: "x"))
        let kept = Candidate(rule: .conversations, url: h.path(".codex/sessions/a.jsonl"), root: h.path(".codex/sessions"),
                             bytes: 100_000, lastActivity: nil, verdict: .keep(reason: "y"))
        let r = report(h, candidates: [next, kept])
        XCTAssertEqual(area(r, "projects").cleanable, 200_000)
        XCTAssertEqual(area(r, "agentData").cleanable, 0)
    }

    /// 工作树整个可删时，里面的依赖、缓存不能再算一遍。
    func testNestedCleanableItemsAreNotCountedTwice() {
        let h = home()
        let outer = Candidate(rule: .workCopies, url: h.path("Projects/app"), root: h.path("Projects"),
                              bytes: 500_000, lastActivity: nil, verdict: .delete(reason: "x"))
        let inner = Candidate(rule: .buildCaches, url: h.path("Projects/app/.next"), root: h.path("Projects"),
                              bytes: 200_000, lastActivity: nil, verdict: .delete(reason: "x"))
        XCTAssertEqual(area(report(h, candidates: [outer, inner]), "projects").cleanable, 500_000)
    }

    func testEachAreaListsItsLargestEntries() {
        let h = home()
        let projects = area(report(h), "projects")
        XCTAssertEqual(projects.largest.first?.path, h.path("Projects/app").path)
        XCTAssertTrue(projects.note.count > 10)
    }

    func testRoundTripsThroughFile() throws {
        let h = home()
        var r = report(h)
        r.date = r.date.wholeSeconds
        try r.save(to: h.env().storageFile)
        XCTAssertEqual(StorageReport.load(from: h.env().storageFile), r)
    }
}

final class VolumeUsageTests: XCTestCase {
    func testReadsVolumeSizesFromDiskutilOutput() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Containers</key><array><dict>
          <key>CapacityCeiling</key><integer>994662584320</integer>
          <key>Volumes</key><array>
            <dict><key>Name</key><string>Macintosh HD</string><key>Roles</key><array><string>System</string></array><key>CapacityInUse</key><integer>13700000000</integer></dict>
            <dict><key>Name</key><string>Preboot</string><key>Roles</key><array><string>Preboot</string></array><key>CapacityInUse</key><integer>11000000000</integer></dict>
            <dict><key>Name</key><string>Recovery</string><key>Roles</key><array><string>Recovery</string></array><key>CapacityInUse</key><integer>1500000000</integer></dict>
            <dict><key>Name</key><string>Data</string><key>Roles</key><array><string>Data</string></array><key>CapacityInUse</key><integer>595000000000</integer></dict>
            <dict><key>Name</key><string>VM</string><key>Roles</key><array><string>VM</string></array><key>CapacityInUse</key><integer>10700000000</integer></dict>
          </array></dict></array></dict></plist>
        """
        let usage = try XCTUnwrap(VolumeUsage.parse(Data(plist.utf8)))
        XCTAssertEqual(usage.total, 994_662_584_320)
        XCTAssertEqual(usage.dataUsed, 595_000_000_000)
        XCTAssertEqual(usage.system, 13_700_000_000)
        XCTAssertEqual(usage.preboot, 11_000_000_000)
        XCTAssertEqual(usage.recovery, 1_500_000_000)
        XCTAssertEqual(usage.vm, 10_700_000_000)
    }

    func testRejectsOutputWithoutADataVolume() {
        XCTAssertNil(VolumeUsage.parse(Data("<plist><dict/></plist>".utf8)))
    }
}

extension StorageReportTests {
    /// 临时目录不属于「系统、不能删」：里面多是应用和 agent 留下的临时文件。单独成一块。
    func testTemporaryFilesAreTheirOwnAreaNotPartOfTheSystem() {
        let h = home()
        h.file("tmp/X/com.google.Chrome.code_sign_clone/code_sign_clone.abc/Chrome", bytes: 90_000)
        h.file("tmp/T/installer/setup.pkg", bytes: 40_000)
        let volumes = VolumeUsage(total: 20_000_000, dataUsed: 10_000_000, system: 1_000, preboot: 0, recovery: 0, vm: 0)
        let r = StorageReport.build(env: h.env(), candidates: [], volumes: volumes, applications: [], systemPaths: [],
                                    tempDirs: [h.path("tmp")])
        let temp = r.areas.first { $0.id == "temp" }
        XCTAssertNotNil(temp)
        XCTAssertGreaterThanOrEqual(temp?.bytes ?? 0, 130_000)
        XCTAssertEqual(r.areas.first { $0.id == "system" }?.bytes, 1_000)
        XCTAssertEqual(temp?.largest.first?.path, h.path("tmp/X").path)
    }
}
