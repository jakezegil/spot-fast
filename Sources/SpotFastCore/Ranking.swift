import Foundation

public struct UsageRecord: Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public let url: String
    public var opens: Int
    public var lastOpened: Date
    public init(id: String, title: String, url: String, opens: Int = 1, lastOpened: Date = Date()) {
        self.id = id; self.title = title; self.url = url; self.opens = opens; self.lastOpened = lastOpened
    }
    /// A bounded tie-breaker. Relevance remains stronger than habitual use.
    public func boost(now: Date = Date()) -> Double {
        let days = max(0, now.timeIntervalSince(lastOpened) / 86400)
        return min(95, log2(Double(max(0, opens)) + 1) * 12 + 45 / (1 + days))
    }
}

public enum SelectionPolicy {
    public static func resolve(previousID: String?, previousIndex: Int, userNavigated: Bool, ids: [String]) -> Int {
        guard !ids.isEmpty else { return 0 }
        guard userNavigated else { return 0 }
        if let previousID, let index = ids.firstIndex(of: previousID) { return index }
        return min(max(0, previousIndex), ids.count - 1)
    }
}

public enum PathExclusion {
    public static func contains(_ path: String, roots: [String]) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        return roots.contains { root in
            let value = URL(fileURLWithPath: root).standardizedFileURL.path
            return normalized == value || normalized.hasPrefix(value == "/" ? "/" : value + "/")
        }
    }
}
