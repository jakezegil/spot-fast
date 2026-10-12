import Foundation

/// Provider-independent relevance. Personalization cannot bridge match tiers.
public enum ResultRanking {
    public enum Match { case exact, word, prefix, wordPrefix, initials, substring, fuzzy }
    private static let locale = Locale(identifier: "en_US_POSIX")
    private static func folded(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
    private static func tokens(_ value: String) -> [String] {
        var words: [String] = []
        value.enumerateSubstrings(in: value.startIndex..<value.endIndex, options: .byWords) { word, _, _, _ in
            guard let word else { return }
            let chars = Array(word)
            var part = ""
            for i in chars.indices {
                let char = chars[i]
                if !char.isLetter && !char.isNumber {
                    if !part.isEmpty { words.append(folded(part)); part = "" }
                    continue
                }
                if i > 0, !part.isEmpty {
                    let previous = chars[i - 1]
                    let camel = char.isUppercase && (previous.isLowercase || (previous.isUppercase && i + 1 < chars.count && chars[i + 1].isLowercase))
                    if camel || (char.isNumber != previous.isNumber && (previous.isLetter || previous.isNumber)) {
                        words.append(folded(part)); part = ""
                    }
                }
                part.append(char)
            }
            if !part.isEmpty { words.append(folded(part)) }
        }
        return words
    }
    public static func match(_ name: String, query: String, allowInitials: Bool = false) -> Match? {
        let text = folded(name), q = folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return nil }
        if text == q { return .exact }
        let words = tokens(name), parts = tokens(query)
        if parts.count == 1, words.contains(q) { return .word }
        if text.hasPrefix(q) { return .prefix }
        if !parts.isEmpty {
            var cursor = 0, exact = true, found = true
            for part in parts {
                guard let i = words.indices.first(where: { $0 >= cursor && words[$0].hasPrefix(part) }) else { found = false; break }
                exact = exact && words[i] == part; cursor = i + 1
            }
            if found { return exact ? .word : .wordPrefix }
            if parts.count > 1 {
                var unused = Set(words.indices)
                for part in parts {
                    guard let i = unused.sorted().first(where: { words[$0].hasPrefix(part) }) else { return nil }
                    unused.remove(i)
                }
                return .wordPrefix
            }
        }
        if allowInitials, q.count >= 2, q.allSatisfy({ $0.isASCII && $0.isLetter }),
           String(words.compactMap(\.first)).hasPrefix(q) { return .initials }
        guard q.count >= 3 else { return nil }
        if text.contains(q) { return .substring }
        // Arbitrary, widely separated letters create accidental app matches.
        var cursor = text.startIndex, first: String.Index?, last: String.Index?
        for char in q {
            guard cursor < text.endIndex, let i = text[cursor...].firstIndex(of: char) else { return nil }
            if first == nil { first = i }; last = i; cursor = text.index(after: i)
        }
        if let first, let last, text.distance(from: first, to: last) + 1 <= q.count * 2 { return .fuzzy }
        return nil
    }
    public static func applicationScore(_ name: String, query: String) -> Double? {
        let q = query.lowercased().hasSuffix(".app") ? String(query.dropLast(4)) : query
        guard let match = match(name, query: q, allowInitials: true) else { return nil }
        let base: Double
        switch match {
        case .exact: base = 1400
        case .word: base = 1300
        case .prefix: base = q.count >= 3 ? 1200 : 900
        case .wordPrefix, .initials: base = 900
        case .substring: base = 650
        case .fuzzy: base = 300
        }
        return base + quality(name)
    }
    public static func fileNameScore(_ name: String, query: String) -> Double? {
        let ext = (name as NSString).pathExtension
        if !hasFileIntent(query), !ext.isEmpty, ext.count <= 6, ext.allSatisfy({ $0.isLetter || $0.isNumber }),
           folded((name as NSString).deletingPathExtension) == folded(query) { return 1000 + quality(name) }
        guard let match = match(name, query: query) else { return nil }
        let base: Double
        switch match {
        case .exact: base = 1000
        case .word: base = 800
        case .prefix: base = 800
        case .wordPrefix, .initials: base = 700
        case .substring: base = 500
        case .fuzzy: base = 300
        }
        return base + quality(name)
    }
    private static func quality(_ name: String) -> Double { max(0, 20 - Double(name.count) / 4) }
    public static func hasFileIntent(_ query: String) -> Bool {
        if query.contains("/") || query.hasPrefix("~") || query.hasPrefix(".") || query.contains(":") || query.hasPrefix("'") { return true }
        let ext = (query as NSString).pathExtension
        return !ext.isEmpty && ext.lowercased() != "app" && ext.count <= 6 && ext.allSatisfy({ $0.isLetter || $0.isNumber })
    }
    /// Only recognizable ancestor classes are demoted. No filesystem reads.
    public static func pathPenalty(_ path: String, query: String, filesOnly: Bool = false, application: Bool = false) -> Double {
        let ancestors = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropLast()).map { folded($0) }
        let requested = Set(folded(query).split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == ":" }).map(String.init))
        func mentioned(_ values: [String]) -> Bool { values.contains { requested.contains($0) } }
        func containsPair(_ first: String, _ second: String) -> Bool {
            zip(ancestors, ancestors.dropFirst()).contains { $0 == first && $1 == second }
        }
        var penalty: Double = 0
        let dependencies = ["node_modules", ".git", "__pycache__", ".venv", "site-packages", ".gradle", ".next", ".build", "deriveddata", "pods"]
        if ancestors.contains(where: { dependencies.contains($0) && !requested.contains($0) }) { penalty = 400 }
        if containsPair("pkg", "mod") && !mentioned(["pkg", "mod"]) { penalty = max(penalty, 400) }
        let caches = ["caches", "cacheddata", "cache", ".cache"]
        if ancestors.contains(where: { ["caches", "cacheddata", ".cache"].contains($0) && !requested.contains($0) }) { penalty = max(penalty, 450) }
        // A plain directory called 'cache' is not enough; scope it to Library.
        if ancestors.contains("library"), ancestors.contains("cache"), !mentioned(caches) { penalty = max(penalty, 450) }
        if containsPair("homebrew", "cellar"), !requested.contains("cellar") { penalty = max(penalty, 400) }
        let support = ["application support", "containers", "group containers"]
        if containsPair("library", "application support") || containsPair("library", "containers") || containsPair("library", "group containers") || containsPair("library", "safari") || folded(path).hasSuffix("/library/safari") {
            if !mentioned(support + ["library"]) && !folded(query).contains("application support") { penalty = max(penalty, 300) }
        }
        if ancestors.contains(where: { $0.hasSuffix(".app") && !requested.contains($0) }) { penalty = max(penalty, 450) }
        if containsPair("library", "developer"), ancestors.contains(where: { ["coresimulator", "xcode", "commandlinetools"].contains($0) && !requested.contains($0) }) {
            penalty = max(penalty, 400)
        }
        // Recognize versioned Go SDK distributions, not arbitrary sdk projects.
        if let sdk = ancestors.firstIndex(of: "sdk"), sdk + 1 < ancestors.count {
            let version = ancestors[sdk + 1]
            if version.hasPrefix("go"), version.dropFirst(2).first?.isNumber == true,
               !mentioned(["sdk", version]) { penalty = max(penalty, 350) }
        }
        // Installed top-level apps remain applications, including macOS apps.
        let installedSystemApp = application && ["/System/Applications/", "/System/Library/CoreServices/", "/System/Cryptexes/App/System/Applications/"].contains { path.hasPrefix($0) }
        if !installedSystemApp, ancestors.count > 1, ["system", "usr", "bin", "sbin"].contains(ancestors[1]), !requested.contains(ancestors[1]) {
            penalty = max(penalty, 400)
        }
        return filesOnly ? penalty * 0.4 : penalty
    }
    public static func personalized(_ base: Double, usage: Double, pinned: Bool) -> Double {
        base + min(25, max(0, usage) * 25 / 95) + (pinned ? 15 : 0)
    }
}
