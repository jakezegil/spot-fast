import XCTest
@testable import SpotFastCore

final class ContactIndexTests: XCTestCase {
    private let alex = ContactEntry(id: "alex", name: "Alex García", addresses: [ContactAddress(label: "Mobile", value: "+1 (202) 555-0100"), ContactAddress(label: "Work", value: "alex+work@example.com", isEmail: true)])
    func testNameTokensAccentsAndAddresses() {
        let index = ContactIndex(entries: [alex, ContactEntry(id: "other", name: "Alexandra Example", addresses: [])])
        XCTAssertEqual(index.search("alex").first?.entry.id, "alex")
        XCTAssertEqual(index.search("garcia").first?.entry.id, "alex")
        XCTAssertEqual(index.search("gar al").first?.entry.id, "alex")
        XCTAssertEqual(index.search("202-555-0100").first?.entry.id, "alex")
        XCTAssertEqual(index.search("alex+work@example.com").first?.entry.id, "alex")
        XCTAssertTrue(index.search("unrelated").isEmpty)
        XCTAssertEqual(index.search("", limit: 1).count, 1)
    }
    func testRecipientOnlyURLsRejectInjectionAndExtensions() {
        for value in ["+12025550100?body=hello", "+1202;5550100", "1202,5550100", "1202\n5550100", "2025550100 ext 5", "12+3456"] {
            XCTAssertNil(ContactAddress(label: "Phone", value: value).messagesURL, value)
        }
        for value in ["alex@example.com?body=hello", "a@example.com&x=y", "a\nb@example.com", "a@example.com,b@example.com"] {
            XCTAssertNil(ContactAddress(label: "Email", value: value, isEmail: true).messagesURL, value)
        }
        let phone = alex.addresses[0].messagesURL!
        XCTAssertEqual(phone.absoluteString, "imessage://+12025550100")
        XCTAssertNil(phone.query); XCTAssertNil(phone.fragment)
        XCTAssertEqual(alex.addresses[1].messagesURL?.absoluteString, "imessage://alex+work@example.com")
    }
    func testBoundedResultsAndDeterministicOrder() {
        let entries = (0..<100).map { ContactEntry(id: String($0), name: "Alex \($0)", addresses: []) }
        let index = ContactIndex(entries: entries)
        XCTAssertEqual(index.search("alex", limit: 7).count, 7)
        XCTAssertEqual(index.search("alex").map(\.entry.id), index.search("alex").map(\.entry.id))
        XCTAssertEqual(index.search("alex 99").first?.entry.id, "99")
        XCTAssertTrue(index.search("alex", limit: 0).isEmpty)
        XCTAssertTrue(index.search("alex", cancelled: { true }).isEmpty)
    }
    func testChromePrefixesStayBelowAppsAndClearFileMatches() {
        let index = ContactIndex(entries: [
            ContactEntry(id: "chris", name: "Chris Example", addresses: []),
            ContactEntry(id: "chrome", name: "Chrome Support", addresses: []),
            ContactEntry(id: "email", name: "Alex Example", addresses: [ContactAddress(label: "Work", value: "alex@chrome.example", isEmail: true)]),
            ContactEntry(id: "short", name: "Ch", addresses: [])
        ])
        for query in ["ch", "chr", "chrome"] {
            let hits = index.search(query)
            XCTAssertFalse(hits.isEmpty)
            XCTAssertFalse(hits.contains { $0.entry.id == "email" }, query)
            let app = ResultRanking.applicationScore("Google Chrome", query: query)!
            let file = ResultRanking.fileNameScore("Chrome notes.txt", query: query)!
            for hit in hits {
                XCTAssertLessThan(ResultRanking.personalized(hit.score, usage: 95, pinned: true), app, query)
                // Exact contact name tokens can beat a mere filename prefix,
                // while short/broad prefixes must not displace filename matches.
                if query != "chrome" { XCTAssertLessThan(hit.score, file, query) }
            }
        }
    }
    func testAddressMatchesRequireRecipientIntent() {
        let index = ContactIndex(entries: [ContactEntry(id: "person", name: "Alex Example", addresses: [
            ContactAddress(label: "Email", value: "alex@gmail.com", isEmail: true),
            ContactAddress(label: "Mobile", value: "+1 202 555 0100")
        ])])
        for query in ["mail", "gmail", "com", "202"] { XCTAssertTrue(index.search(query).isEmpty, query) }
        XCTAssertEqual(index.search("alex@gmail.com").first?.score, 1250)
        XCTAssertEqual(index.search("alex@gm").first?.score, 900)
        XCTAssertEqual(index.search("+1 (202) 555-0100").first?.score, 1250)
        XCTAssertEqual(index.search("2025550100").first?.score, 900)
        XCTAssertEqual(index.search("0100").first?.score, 200)
    }
    func testSpecificPeopleRemainUsefulWithoutInflatedRepeatedTokens() {
        let index = ContactIndex(entries: [alex])
        XCTAssertEqual(index.search("alex gar").first?.score, 850)
        XCTAssertEqual(index.search("gar al").first?.entry.id, "alex")
        XCTAssertEqual(index.search("alex garcia").first?.score, 950)
        XCTAssertEqual(index.search("alex").first?.score, 820)
        XCTAssertTrue(index.search("alex alex").isEmpty)
        XCTAssertLessThan(index.search("a g").first?.score ?? 0, 600)
        XCTAssertLessThan(index.search("alex").first!.score, ResultRanking.applicationScore("Alex Editor", query: "alex")!)
        XCTAssertLessThan(index.search("alex garcia").first!.score, ResultRanking.fileNameScore("Alex Garcia.pdf", query: "alex garcia")!)
    }
    func testLargeAddressBookSearchLatency() {
        let entries = (0..<10_000).map { ContactEntry(id: String($0), name: "Person Example \($0)", addresses: [ContactAddress(label: "Mobile", value: "+1202555\(String(format: "%04d", $0))")]) }
        let index = ContactIndex(entries: entries)
        var durations: [Double] = []
        for query in ["per", "example", "person 9999", "nothing", "2025550001", "exam", "person", "person example 99", "9999", "person example 5000"] {
            let start = ProcessInfo.processInfo.systemUptime
            _ = index.search(query)
            durations.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        let median = durations.sorted()[durations.count / 2]
        print("Contact search benchmark: 10,000 contacts, median \(String(format: "%.2f", median)) ms, max \(String(format: "%.2f", durations.max()!)) ms")
        XCTAssertLessThan(median, 100, "Contact searches must avoid perceptible delays even in debug builds")
    }
}
