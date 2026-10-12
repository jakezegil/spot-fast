import XCTest
@testable import SpotFastCore

final class CoreTests: XCTestCase {
    func testArithmeticPrecedenceAndAssociativity() {
        XCTAssertEqual(Calculator.evaluate("2 + 3 * 4"), 14)
        XCTAssertEqual(Calculator.evaluate("(2 + 3) * 4"), 20)
        XCTAssertEqual(Calculator.evaluate("2^3^2"), 512)
        XCTAssertEqual(Calculator.evaluate("-2^2"), -4)
        XCTAssertEqual(Calculator.evaluate("10 % 3"), 1)
    }
    func testArithmeticRejectsCodeAndNonfiniteValues() {
        for input in ["1/0", "0/0", "2+", "2**3", "2+foo", "$(touch /tmp/x)", "1+2;exit", String(repeating: "(", count: 100) + "1+2"] {
            XCTAssertNil(Calculator.evaluate(input), input)
        }
    }
    func testConversions() {
        XCTAssertEqual(Converter.convert("32 f to c"), "0 c")
        XCTAssertEqual(Converter.convert("1 mi in km"), "1.609344 km")
        XCTAssertEqual(Converter.convert("1 gib to mib"), "1024 mib")
        XCTAssertNil(Converter.convert("1 kg to m"))
        XCTAssertNil(Converter.convert("nan m to ft"))
    }
    func testFuzzyRanking() {
        XCTAssertGreaterThan(Matcher.score("Safari", query: "safari")!, Matcher.score("Safari Technology Preview", query: "safari")!)
        XCTAssertNotNil(Matcher.score("Visual Studio Code", query: "vsc"))
        XCTAssertNotNil(Matcher.score("Résumé", query: "resume"))
        XCTAssertNil(Matcher.score("Safari", query: "terminal"))
    }
    func testFSearchRejectsUntrustedPathBeforeConnecting() {
        XCTAssertThrowsError(try FSearchClient.search("hello", socketPath: "/tmp/absent/fsearch.sock"))
        XCTAssertThrowsError(try FSearchClient.search(String(repeating: "a", count: 1025), socketPath: "/unused"))
    }
}
