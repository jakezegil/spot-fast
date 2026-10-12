import XCTest
@testable import SpotFastCore

final class DiscoveryAndCoverageTests: XCTestCase {
    func testSmallAppTyposAndTranspositionsRemainBelowCorrectNames() {
        XCTAssertNotNil(ResultRanking.applicationScore("Google Chrome", query: "chorme"))
        XCTAssertNotNil(ResultRanking.applicationScore("Safari", query: "safri"))
        XCTAssertGreaterThan(ResultRanking.applicationScore("Google Chrome", query: "chrome")!, ResultRanking.applicationScore("Google Chrome", query: "chorme")!)
        XCTAssertNil(ResultRanking.applicationScore("Safari", query: "zzzzzz"))
        XCTAssertNil(ResultRanking.applicationScore("Google Chrome", query: "chorme.txt"))
        XCTAssertNil(ResultRanking.typoDistance("Chrome", query: "cr"))
    }
    func testAliasValidationExactPriorityAndBoundaries() {
        let alias = ApplicationAlias(name: " Browser ", applicationPath: "/Applications/Google Chrome.app")
        XCTAssertTrue(alias.isValid)
        XCTAssertEqual(alias.score(query: "browser"), 1850)
        XCTAssertEqual(alias.score(query: "BROWSER"), 1850)
        XCTAssertEqual(alias.score(query: "bro"), 1250)
        XCTAssertNil(alias.score(query: "browser file"))
        XCTAssertNil(ApplicationAlias(name: "https://example.com", applicationPath: "/Applications/Chrome.app").score(query: "https://example.com"))
        XCTAssertFalse(ApplicationAlias(name: "browser", applicationPath: "relative.app").isValid)
        XCTAssertFalse(ApplicationAlias(name: "browser", applicationPath: "/tmp/script.sh").isValid)
    }
    private func temporary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func application(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier":"test.fixture.app", "CFBundlePackageType":"APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    func testInstalledRemovedNestedAndLinkedApplicationsRefresh() throws {
        try temporary { root in
            XCTAssertTrue(ApplicationScanner.scan(roots: [root]).applications.isEmpty)
            let app = root.appendingPathComponent("Tools/New App.app")
            try application(app)
            let link = root.appendingPathComponent("Linked App.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            let snapshot = ApplicationScanner.scan(roots: [root])
            XCTAssertTrue(snapshot.applications.contains { $0.lastPathComponent == app.lastPathComponent })
            XCTAssertTrue(snapshot.applications.contains { $0.lastPathComponent == link.lastPathComponent })
            XCTAssertTrue(snapshot.directories.contains { $0.lastPathComponent == "Tools" })
            try FileManager.default.removeItem(at: app)
            XCTAssertTrue(ApplicationScanner.scan(roots: [root]).applications.isEmpty)
        }
    }
    func testSelectedFolderNamesExcludePackagesAndDirectorySymlinkEscapes() throws {
        try temporary { root in
            let selected = root.appendingPathComponent("selected")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data().write(to: selected.appendingPathComponent("report.txt"))
            try Data().write(to: outside.appendingPathComponent("outside-secret.txt"))
            try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("link"), withDestinationURL: outside)
            try application(selected.appendingPathComponent("Example.app"))
            let scan = FolderCatalog.scan(root: selected, excluded: [], hidden: false)
            XCTAssertTrue(scan.entries.contains { $0.path.hasSuffix("report.txt") })
            XCTAssertFalse(scan.entries.contains { $0.path.hasSuffix("outside-secret.txt") || $0.path.hasSuffix("Info.plist") })
            XCTAssertEqual(FolderCatalog.search("report", entries: scan.entries).count, 1)
        }
    }
    func testFolderExclusionsLimitsAndCancellationAreReported() throws {
        try temporary { root in
            for name in ["a.txt", "b.txt", "c.txt"] { try Data().write(to: root.appendingPathComponent(name)) }
            let limited = FolderCatalog.scan(root: root, excluded: [], hidden: false, limit: 1)
            XCTAssertTrue(limited.limited); XCTAssertEqual(limited.entries.count, 1)
            XCTAssertTrue(FolderCatalog.scan(root: root, excluded: [root.path], hidden: false).entries.isEmpty)
            XCTAssertTrue(FolderCatalog.scan(root: root, excluded: [], hidden: false, cancelled: { true }).entries.isEmpty)
            XCTAssertTrue(FolderCatalog.search("a", entries: limited.entries, cancelled: { true }).isEmpty)
        }
    }
    @MainActor func testFilesystemMonitorDetectsAnInstalledAppWithoutRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = DirectoryMonitor()
        let changed = expectation(description: "Application directory changed")
        monitor.changed = { changed.fulfill() }
        monitor.watch([root])
        try application(root.appendingPathComponent("New App.app"))
        await fulfillment(of: [changed], timeout: 5)
        XCTAssertEqual(ApplicationScanner.scan(roots: [root]).applications.count, 1)
        monitor.watch([])
    }
    func testOverlyBroadRootsAreRejected() {
        for path in ["/", "/Users", "/Volumes", NSHomeDirectory()] {
            XCTAssertFalse(FolderCatalog.allowsRoot(URL(fileURLWithPath: path)))
        }
        XCTAssertTrue(FolderCatalog.allowsRoot(URL(fileURLWithPath: "/Volumes/My Drive")))
    }
    func testReadOnlyFolderBookmarkRoundTrip() throws {
        try temporary { root in
            let folder = try SelectedFolder(url: root)
            XCTAssertEqual(try folder.resolve().standardizedFileURL.path, root.standardizedFileURL.path)
        }
    }
}
