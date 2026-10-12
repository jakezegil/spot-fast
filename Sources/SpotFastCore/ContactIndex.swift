import Foundation

public struct ContactAddress: Equatable, Sendable {
    public let label: String
    public let value: String
    public let isEmail: Bool
    public init(label: String, value: String, isEmail: Bool = false) {
        self.label = label; self.value = value; self.isEmail = isEmail
    }
    public var recipient: String? {
        let raw = value.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, raw.count <= 254, !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if isEmail {
            let pieces = raw.split(separator: "@", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty }),
                  !raw.contains(where: { $0.isWhitespace || "?&#;,:/\\\"<>".contains($0) }) else { return nil }
            return raw
        }
        guard raw.allSatisfy({ "0123456789+()- .".contains($0) }),
              raw.filter({ $0 == "+" }).count <= 1, !raw.contains("+") || raw.first == "+" else { return nil }
        let number = raw.filter { "0123456789+".contains($0) }
        guard (3...20).contains(number.filter(\.isNumber).count) else { return nil }
        return number
    }
    public var messagesURL: URL? {
        guard let recipient, let escaped = recipient.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@.-+_")) else { return nil }
        return URL(string: "imessage://" + escaped)
    }
}

public struct ContactEntry: Sendable {
    public let id: String
    public let name: String
    public let addresses: [ContactAddress]
    fileprivate let foldedName: String
    fileprivate let words: [String]
    fileprivate let emails: [String]
    fileprivate let phoneNumbers: [String]
    public init(id: String, name: String, addresses: [ContactAddress]) {
        self.id = id; self.name = name; self.addresses = addresses.filter { $0.messagesURL != nil }
        foldedName = ContactIndex.fold(name)
        words = foldedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        emails = self.addresses.filter(\.isEmail).compactMap(\.recipient).map(ContactIndex.fold)
        phoneNumbers = self.addresses.filter { !$0.isEmail }.compactMap(\.recipient).map { $0.filter(\.isNumber) }
    }
}

/// Immutable, memory-only snapshot. All expensive normalization happens at load time.
public struct ContactIndex: Sendable {
    public let entries: [ContactEntry]
    public init(entries: [ContactEntry]) { self.entries = entries.sorted { $0.foldedName < $1.foldedName } }
    fileprivate static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func matchesDistinctWords(_ tokens: [String], words: [String]) -> Bool {
        guard tokens.count <= words.count else { return false }
        if tokens.count == 1 { return words.contains { $0.hasPrefix(tokens[0]) } }
        var used = Set<Int>()
        for token in tokens {
            guard let index = words.indices.first(where: { !used.contains($0) && words[$0].hasPrefix(token) }) else { return false }
            used.insert(index)
        }
        return true
    }
    public func search(_ query: String, limit: Int = 60, cancelled: @Sendable () -> Bool = { false }) -> [(entry: ContactEntry, score: Double)] {
        guard limit > 0 else { return [] }
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return entries.prefix(limit).map { ($0, 0) } }
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let number = q.filter { "0123456789".contains($0) }
        let phoneQuery = q.allSatisfy { "0123456789+()- .".contains($0) } && number.count >= 4
        let emailQuery = q.contains("@") && q.count >= 4
        let distinctTokens = tokens.sorted { $0.count > $1.count }
        var best: [(entry: ContactEntry, score: Double)] = []
        for (offset, entry) in entries.enumerated() {
            if offset % 256 == 0 && cancelled() { return [] }
            let score: Double
            // Apps and exact file names win ambiguous launcher queries. Contacts
            // gain strong scores only from a specific name or recipient address.
            if emailQuery && entry.emails.contains(q) { score = 1250 }
            else if phoneQuery && number.count >= 7 && entry.phoneNumbers.contains(number) { score = 1250 }
            else if entry.foldedName == q { score = q.count <= 2 ? 300 : 950 }
            else if entry.words.contains(q) { score = q.count <= 2 ? 300 : 820 }
            else if !tokens.isEmpty && Self.matchesDistinctWords(distinctTokens, words: entry.words) {
                score = tokens.count > 1 ? (tokens.allSatisfy { $0.count >= 2 } ? 850 : 250) : (q.count <= 2 ? 250 : 600)
            }
            else if entry.foldedName.hasPrefix(q) { score = q.count <= 2 ? 250 : 600 }
            else if emailQuery && entry.emails.contains(where: { $0.hasPrefix(q) }) { score = 900 }
            else if phoneQuery && number.count >= 7 && entry.phoneNumbers.contains(where: { $0.hasPrefix(number) || $0.hasSuffix(number) }) { score = 900 }
            else if emailQuery && entry.emails.contains(where: { $0.contains(q) }) { score = 200 }
            else if phoneQuery && entry.phoneNumbers.contains(where: { $0.contains(number) }) { score = 200 }
            else if q.count >= 3 && entry.foldedName.contains(q) { score = 250 }
            else { continue }
            // Bounded insertion keeps allocations and sorting independent of address-book size.
            let position = best.firstIndex { $0.score < score } ?? best.count
            if position < limit { best.insert((entry, score), at: position); if best.count > limit { best.removeLast() } }
        }
        return best
    }
}
