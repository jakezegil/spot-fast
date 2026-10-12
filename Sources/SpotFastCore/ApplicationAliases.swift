import Foundation

public struct ApplicationAlias: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let applicationPath: String
    public init(name: String, applicationPath: String, id: UUID = UUID()) {
        self.id = id; self.name = name.trimmingCharacters(in: .whitespacesAndNewlines); self.applicationPath = applicationPath
    }
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public var isValid: Bool {
        !name.isEmpty && name.count <= 32 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
            && applicationPath.hasPrefix("/") && !applicationPath.contains("\0") && applicationPath.utf8.count < 4096 && applicationPath.hasSuffix(".app")
    }
    public func score(query: String) -> Double? {
        let q = Self.normalized(query), alias = Self.normalized(name)
        guard isValid, !q.isEmpty else { return nil }
        if alias == q { return 1850 }
        if q.count >= 2 && alias.hasPrefix(q) { return 1250 }
        return nil
    }
}
