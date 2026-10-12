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
        return URL(string: "imessage:" + escaped)
    }
}

public struct ContactEntry: Sendable {
    public let id: String
    public let name: String
    public let addresses: [ContactAddress]
    fileprivate let foldedName: String
    fileprivate let words: [String]
    fileprivate let searchableAddresses: [String]
    public init(id: String, name: String, addresses: [ContactAddress]) {
        self.id = id; self.name = name; self.addresses = addresses.filter { $0.messagesURL != nil }
        foldedName = ContactIndex.fold(name)
        words = foldedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        searchableAddresses = addresses.compactMap(\.recipient).map(ContactIndex.fold)
    }
}

/// Immutable, memory-only snapshot. All expensive normalization happens at load time.
public struct ContactIndex: Sendable {
    public let entries: [ContactEntry]
    public init(entries: [ContactEntry]) { self.entries = entries.sorted { $0.foldedName < $1.foldedName } }
    fileprivate static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public func search(_ query: String, limit: Int = 60, cancelled: @Sendable () -> Bool = { false }) -> [(entry: ContactEntry, score: Double)] {
        guard limit > 0 else { return [] }
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return entries.prefix(limit).map { ($0, 0) } }
        let tokens = q.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let number = q.filter { "0123456789+".contains($0) }
        let phoneQuery = q.allSatisfy { "0123456789+()- .".contains($0) } && number.count >= 3
        var best: [(entry: ContactEntry, score: Double)] = []
        for (offset, entry) in entries.enumerated() {
            if offset % 256 == 0 && cancelled() { return [] }
            let score: Double
            if entry.foldedName == q { score = 1380 }
            else if entry.words.contains(q) { score = 1280 }
            else if entry.foldedName.hasPrefix(q) { score = 1180 }
            else if !tokens.isEmpty && tokens.allSatisfy({ token in entry.words.contains { $0.hasPrefix(token) } }) { score = 880 }
            else if entry.searchableAddresses.contains(where: { $0 == q || (phoneQuery && $0 == number) }) { score = 1380 }
            else if q.count >= 3 && entry.searchableAddresses.contains(where: { $0.contains(phoneQuery ? number : q) }) { score = 780 }
            else if q.count >= 2 && entry.foldedName.contains(q) { score = 620 }
            else { continue }
            // Bounded insertion keeps allocations and sorting independent of address-book size.
            let position = best.firstIndex { $0.score < score } ?? best.count
            if position < limit { best.insert((entry, score), at: position); if best.count > limit { best.removeLast() } }
        }
        return best
    }
}
