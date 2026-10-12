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
        XCTAssertEqual(phone.absoluteString, "imessage:+12025550100")
        XCTAssertNil(phone.query); XCTAssertNil(phone.fragment)
        XCTAssertEqual(alex.addresses[1].messagesURL?.absoluteString, "imessage:alex+work@example.com")
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
