import XCTest
@testable import SpotFastCore

final class RankingTests: XCTestCase {
    func testManualSelectionFollowsIdentityWhenProviderResultsArrive() {
        XCTAssertEqual(SelectionPolicy.resolve(previousID: "chosen", previousIndex: 1,
            userNavigated: true, ids: ["new", "first", "chosen"]), 2)
    }
    func testNewQuerySelectsBestMatchRatherThanPreviousIdentity() {
        XCTAssertEqual(SelectionPolicy.resolve(previousID: "old", previousIndex: 2,
            userNavigated: false, ids: ["exact", "old"]), 0)
    }
    func testRemovedSelectionClampsAndEmptyResultsRemainSafe() {
        XCTAssertEqual(SelectionPolicy.resolve(previousID: "gone", previousIndex: 8,
            userNavigated: true, ids: ["a", "b"]), 1)
        XCTAssertEqual(SelectionPolicy.resolve(previousID: "gone", previousIndex: 8,
            userNavigated: true, ids: []), 0)
    }
    func testExclusionsUseDirectoryBoundariesAndNormalizePaths() {
        XCTAssertTrue(PathExclusion.contains("/Users/test/private/report.pdf", roots: ["/Users/test/private/"]))
        XCTAssertTrue(PathExclusion.contains("/Users/test/public/../private", roots: ["/Users/test/private"]))
        XCTAssertFalse(PathExclusion.contains("/Users/test/private-other/report.pdf", roots: ["/Users/test/private"]))
        XCTAssertTrue(PathExclusion.contains("/anything", roots: ["/"]))
    }
    func testUsageBoostIsBoundedAndDecays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recent = UsageRecord(id: "a", title: "A", url: "file:///a", opens: 100_000, lastOpened: now)
        XCTAssertLessThanOrEqual(recent.boost(now: now), 95)
        let oneOpen = UsageRecord(id: "a", title: "A", url: "file:///a", lastOpened: now)
        XCTAssertGreaterThan(oneOpen.boost(now: now), oneOpen.boost(now: now.addingTimeInterval(30 * 86400)))
        XCTAssertGreaterThanOrEqual(oneOpen.boost(now: now.addingTimeInterval(-86400)), 0)
    }
}
