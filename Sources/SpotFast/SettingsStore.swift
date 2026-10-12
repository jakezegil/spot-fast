import AppKit
import Combine
import Darwin
import SpotFastCore

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}
enum WebEngine: String, CaseIterable, Identifiable {
    case google, duckduckgo, bing
    var id: String { rawValue }
    var title: String { switch self { case .google: return "Google"; case .duckduckgo: return "DuckDuckGo"; case .bing: return "Bing" } }
    func url(query: String) -> URL? {
        var parts = URLComponents(string: self == .google ? "https://www.google.com/search" : self == .bing ? "https://www.bing.com/search" : "https://duckduckgo.com/")!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts.url
    }
}

@MainActor final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private let saveChanges: Bool
    var changed: (() -> Void)?
    @Published var commandSpace: Bool { didSet { persist("commandSpace", commandSpace) } }
    @Published var appearance: AppearanceChoice { didSet { persist("appearance", appearance.rawValue) } }
    @Published var compactRows: Bool { didSet { persist("compactRows", compactRows) } }
    @Published var rememberQuery: Bool { didSet { persist("rememberQuery", rememberQuery) } }
    @Published var useFSearch: Bool { didSet { persist("useFSearch", useFSearch) } }
    @Published var useMetadata: Bool { didSet { persist("useMetadata", useMetadata) } }
    @Published var useCalculator: Bool { didSet { persist("useCalculator", useCalculator) } }
    @Published var useSystemSettings: Bool { didSet { persist("useSystemSettings", useSystemSettings) } }
    @Published var useDictionary: Bool { didSet { persist("useDictionary", useDictionary) } }
    @Published var useWeb: Bool { didSet { persist("useWeb", useWeb) } }
    @Published var webEngine: WebEngine { didSet { persist("webEngine", webEngine.rawValue) } }
    @Published var learnUsage: Bool { didSet { persist("learnUsage", learnUsage) } }
    @Published var showHiddenFiles: Bool { didSet { persist("showHiddenFiles", showHiddenFiles) } }
    @Published var excludedFolders: [String] { didSet { persist("excludedFolders", excludedFolders) } }
    @Published var pinnedPaths: [String] { didSet { persist("pinnedPaths", pinnedPaths) } }
    @Published var selectedFolders: [SelectedFolder] { didSet { if let bytes = try? JSONEncoder().encode(selectedFolders) { persist("selectedFolders", bytes) } } }
    @Published var applicationAliases: [ApplicationAlias] { didSet { if let bytes = try? JSONEncoder().encode(applicationAliases) { persist("applicationAliases", bytes) } } }
    @Published var shortcutError: String?
    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        self.defaults = defaults; self.saveChanges = persist
        commandSpace = defaults.object(forKey: "commandSpace") as? Bool ?? true
        appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "system") ?? .system
        compactRows = defaults.bool(forKey: "compactRows")
        rememberQuery = defaults.bool(forKey: "rememberQuery")
        useFSearch = defaults.object(forKey: "useFSearch") as? Bool ?? true
        useMetadata = defaults.object(forKey: "useMetadata") as? Bool ?? true
        useCalculator = defaults.object(forKey: "useCalculator") as? Bool ?? true
        useSystemSettings = defaults.object(forKey: "useSystemSettings") as? Bool ?? true
        useDictionary = defaults.object(forKey: "useDictionary") as? Bool ?? true
        useWeb = defaults.object(forKey: "useWeb") as? Bool ?? true
        webEngine = WebEngine(rawValue: defaults.string(forKey: "webEngine") ?? "google") ?? .google
        learnUsage = defaults.object(forKey: "learnUsage") as? Bool ?? true
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        excludedFolders = defaults.stringArray(forKey: "excludedFolders") ?? []
        pinnedPaths = defaults.stringArray(forKey: "pinnedPaths") ?? []
        selectedFolders = Array((defaults.data(forKey: "selectedFolders").flatMap { try? JSONDecoder().decode([SelectedFolder].self, from: $0) } ?? []).prefix(16))
        applicationAliases = Array((defaults.data(forKey: "applicationAliases").flatMap { try? JSONDecoder().decode([ApplicationAlias].self, from: $0) } ?? []).filter(\.isValid).prefix(128))
    }
    private func persist(_ key: String, _ value: Any) { if saveChanges { defaults.set(value, forKey: key) }; changed?() }
    var shortcutLabel: String { commandSpace ? "⌘ Space" : "⌥ Space" }
    func togglePin(_ url: URL) {
        let path = url.standardizedFileURL.path
        if pinnedPaths.contains(path) { pinnedPaths.removeAll { $0 == path } }
        else { pinnedPaths.append(path) }
    }
}

@MainActor final class UsageStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    private let file: URL?
    init(persist: Bool = true) {
        file = persist ? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/SpotFast/usage.json") : nil
        if let file, Self.privateDirectory(file.deletingLastPathComponent()),
           let info = try? FileManager.default.attributesOfItem(atPath: file.path),
           info[.type] as? FileAttributeType == .typeRegular,
           (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
           (info[.posixPermissions] as? NSNumber)?.intValue == 0o600,
           (info[.size] as? NSNumber)?.intValue ?? Int.max <= 1_048_576,
           let bytes = try? Data(contentsOf: file), bytes.count <= 1_048_576,
           let saved = try? JSONDecoder().decode([UsageRecord].self, from: bytes) {
            records = Array(saved.filter { $0.url.hasPrefix("file://") && $0.opens > 0 && $0.opens <= 100_000 && $0.url.utf8.count < 4096 && $0.id.utf8.count < 4096 }.prefix(100))
        }
    }
    func record(_ result: SearchResult) {
        guard let url = result.fileURL else { return } // Never retain queries, URLs, or calculator values.
        if let i = records.firstIndex(where: { $0.id == result.id }) {
            records[i].opens = min(records[i].opens + 1, 100_000)
            records[i].lastOpened = Date(); records[i].title = result.title
        } else {
            records.append(UsageRecord(id: result.id, title: result.title, url: url.absoluteString))
        }
        records.sort { $0.lastOpened > $1.lastOpened }
        records = Array(records.prefix(100)); save()
    }
    func clear() { records = []; save() }
    func purge(excludedFolders: [String]) {
        let retained = records.filter {
            guard let url = URL(string: $0.url) else { return false }
            return !PathExclusion.contains(url.path, roots: excludedFolders)
                && $0.lastOpened > Date().addingTimeInterval(-90 * 86400)
        }
        if retained != records { records = retained; save() }
    }
    private func save() {
        guard let file, let bytes = try? JSONEncoder().encode(records) else { return }
        // The installed support directory is private. Do not follow a replaced directory.
        let dir = file.deletingLastPathComponent()
        guard Self.privateDirectory(dir) else { return }
        do {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* History is optional; failure must not interrupt launching. */ }
    }
    private static func privateDirectory(_ url: URL) -> Bool {
        guard let info = try? FileManager.default.attributesOfItem(atPath: url.path),
              info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = (info[.posixPermissions] as? NSNumber)?.intValue,
              mode & 0o077 == 0 else { return false }
        return url.resolvingSymlinksInPath().path == url.standardizedFileURL.path
    }
    func boost(id: String) -> Double { records.first { $0.id == id }?.boost() ?? 0 }
}
