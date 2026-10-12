import XCTest
@testable import SpotFastCore

final class ResultRankingTests: XCTestCase {
    private func app(_ name: String, _ query: String) -> Double { ResultRanking.applicationScore(name, query: query)! }
    private func file(_ name: String, _ path: String, _ query: String, filesOnly: Bool = false, usage: Double = 0) -> Double {
        ResultRanking.personalized(ResultRanking.fileNameScore(name, query: query)! - ResultRanking.pathPenalty(path, query: query, filesOnly: filesOnly), usage: usage, pinned: false)
    }
    func testBrowserWordMatchOutranksExactFoldersAndPersonalization() {
        XCTAssertGreaterThan(app("Google Chrome", "chrome"), file("chrome", "/Users/test/Projects/chrome", "chrome", usage: 95))
        XCTAssertGreaterThan(app("Google Chrome", "chrome"), file("Chrome", "/Users/test/Library/Application Support/Google/Chrome", "chrome", usage: 95))
    }
    func testEditorWordMatchOutranksIncidentalApplicationSubstrings() {
        XCTAssertGreaterThan(app("Visual Studio Code", "code"), app("Xcode", "code"))
        XCTAssertGreaterThan(app("Visual Studio Code", "code"), file("code", "/Users/test/Projects/code", "code"))
    }
    func testInitialsAndOrderedOrReorderedMultiwordQueries() {
        XCTAssertNotNil(ResultRanking.applicationScore("Visual Studio Code", query: "vsc"))
        XCTAssertGreaterThan(app("Visual Studio Code", "vsc"), file("vsc", "/opt/homebrew/Cellar/ncurses/version/share/terminfo/vsc", "vsc"))
        XCTAssertNotNil(ResultRanking.applicationScore("Visual Studio Code", query: "visual code"))
        XCTAssertNotNil(ResultRanking.applicationScore("Visual Studio Code", query: "code visual"))
        XCTAssertNotNil(ResultRanking.applicationScore("Google Chrome", query: "gc"))
        XCTAssertNotNil(ResultRanking.applicationScore("VSCodeHelper", query: "code"))
    }
    func testProjectReadmeOutranksSystemAndDependencyReadmes() {
        let project = file("README.md", "/Users/test/Projects/example/README.md", "readme")
        XCTAssertGreaterThan(project, file("README", "/System/Library/Example/README", "readme", usage: 95))
        XCTAssertGreaterThan(project, file("README.md", "/Users/test/Projects/example/node_modules/pkg/README.md", "readme", usage: 95))
    }
    func testFilesScopeKeepsExactMatchesAndTechnicalPathsFindable() {
        XCTAssertNotNil(ResultRanking.fileNameScore("Chrome", query: "chrome"))
        XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/project/node_modules", query: "node_modules"), 0)
        XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/project/node_modules/react", query: "node_modules/react"), 0)
        XCTAssertLessThan(ResultRanking.pathPenalty("/Users/test/project/node_modules/react", query: "react", filesOnly: true), ResultRanking.pathPenalty("/Users/test/project/node_modules/react", query: "react"))
    }
    func testPenaltiesUseComponentsAndPreserveUserSourceDirectories() {
        for folder in ["vendor", "build", "dist", "src", "node_modules-notes", "cache"] {
            XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/Projects/\(folder)/report.md", query: "report"), 0, folder)
        }
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/Library/Caches/tool/report.md", query: "report"), 0)
        XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/Library/Caches/tool/report.md", query: "Caches/report"), 0)
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/Library/Caches/tool/node_modules/report.md", query: "Caches/report"), 0)
    }
    func testNestedApplicationHelpersRemainDemoted() {
        let helper = app("Chrome Helper", "chrome") - ResultRanking.pathPenalty("/Applications/Google Chrome.app/Contents/Frameworks/Chrome Helper.app", query: "chrome")
        XCTAssertLessThan(helper, app("Google Chrome", "chrome"))
    }
    func testRecognizedSimulatorAndSDKFilesRemainBelowUserSource() {
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/Library/Developer/CoreSimulator/Devices/example/data/Library/Safari", query: "safari"), 0)
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/sdk/go1.27.1/misc/chrome", query: "chrome"), 0)
        XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/Projects/sdk/go-project/chrome", query: "chrome"), 0)
        XCTAssertEqual(ResultRanking.pathPenalty("/Users/test/sdk/go1.27.1/misc/chrome", query: "sdk/chrome"), 0)
        XCTAssertEqual(ResultRanking.pathPenalty("/opt/homebrew/Cellar/tool/data/report", query: "Cellar/report"), 0)
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/Library/Safari", query: "safari"), 0)
    }
    func testSystemApplicationsKeepAppPriorityWithoutExemptingDependencies() {
        XCTAssertEqual(ResultRanking.pathPenalty("/System/Applications/Notes.app", query: "notes", application: true), 0)
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/Users/test/project/node_modules/tools/Browser.app", query: "browser", application: true), 0)
        XCTAssertGreaterThan(ResultRanking.pathPenalty("/System/Library/Frameworks/README", query: "readme"), 0)
    }
    func testHistoryAndPinsCannotDefeatAdjacentNameMatchTiers() {
        let weak = ResultRanking.personalized(app("Xcode", "code"), usage: 100000, pinned: true)
        XCTAssertLessThan(weak, app("Visual Studio Code", "code"))
        let prefix = ResultRanking.personalized(ResultRanking.fileNameScore("report draft", query: "report")!, usage: 100000, pinned: true)
        XCTAssertLessThan(prefix, ResultRanking.fileNameScore("report", query: "report")!)
        XCTAssertGreaterThan(ResultRanking.personalized(1000, usage: 20, pinned: false), ResultRanking.personalized(1000, usage: 0, pinned: false))
        // Scale the old 0...95 boost; clamping it would collapse most recent
        // opens to the same value and lose frequency/recency distinctions.
        XCTAssertGreaterThan(ResultRanking.personalized(1000, usage: 95, pinned: false), ResultRanking.personalized(1000, usage: 57, pinned: false))
    }
    func testUnicodeNormalizationAndShortQueryNoise() {
        XCTAssertNotNil(ResultRanking.applicationScore("Café", query: "cafe"))
        XCTAssertEqual(ResultRanking.fileNameScore("Cafe\u{301}.md", query: "café"), ResultRanking.fileNameScore("Café.md", query: "café"))
        XCTAssertNotNil(ResultRanking.applicationScore("Ｆｉｎｄｅｒ", query: "finder"))
        XCTAssertNil(ResultRanking.applicationScore("Calculator", query: "cr"))
        XCTAssertNil(ResultRanking.applicationScore("Calendar", query: "qx"))
    }
    func testFileIntentAndExplicitApplicationExtension() {
        for query in ["package.json", "README.md", "~/Downloads/report", "ext:pdf", ".gitignore"] { XCTAssertTrue(ResultRanking.hasFileIntent(query), query) }
        XCTAssertFalse(ResultRanking.hasFileIntent("chrome"))
        XCTAssertFalse(ResultRanking.hasFileIntent("Safari.app"))
        XCTAssertEqual(app("Safari", "Safari.app"), app("Safari", "Safari"))
    }
}
