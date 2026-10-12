import AppKit
import Combine
import SpotFastCore

enum SearchScope: String, CaseIterable, Identifiable {
    case all, applications, files
    var id: String { rawValue }
    var title: String { self == .all ? "All" : self == .applications ? "Apps" : "Files" }
    var symbol: String { self == .all ? "sparkle.magnifyingglass" : self == .applications ? "square.grid.2x2" : "folder" }
    var next: SearchScope { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
}

struct SearchResult: Identifiable {
    enum Kind { case application, file, folder, calculation, conversion, dictionary, web, settings }
    enum Action { case open(URL), copy(String), settings }
    let id: String
    let title: String
    let subtitle: String
    let kind: Kind
    let action: Action
    var score: Double = 0
    var section: String = "Results"
    var fileURL: URL? {
        if case .open(let url) = action, url.isFileURL { return url }
        return nil
    }
    var symbol: String {
        switch kind {
        case .application: return "app"
        case .file: return "doc"
        case .folder: return "folder"
        case .calculation: return "plus.forwardslash.minus"
        case .conversion: return "arrow.left.arrow.right"
        case .dictionary: return "character.book.closed"
        case .web: return "globe"
        case .settings: return "slider.horizontal.3"
        }
    }
    var verb: String { fileURL != nil ? (kind == .application ? "Open app" : "Open") : (kind == .calculation || kind == .conversion ? "Copy answer" : "Open") }
}

@MainActor final class SearchModel: ObservableObject {
    let settings: SettingsStore
    let usage: UsageStore
    @Published var text = "" { didSet { if text != oldValue { schedule(resetSelection: true) } } }
    @Published var scope = SearchScope.all { didSet { schedule(resetSelection: true) } }
    @Published private(set) var results: [SearchResult] = []
    @Published var selected = 0
    @Published var showActions = false
    @Published var showPreview = false
    @Published private(set) var searching = false
    @Published private(set) var notice: String?
    var dismiss: (() -> Void)?
    var openSettings: (() -> Void)?
    var didOpen: ((URL) -> Void)?
    private var userNavigated = false
    private var active = false
    @Published var showHome = false
    private var debounce: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var apps: [URL] = []
    private var local: [SearchResult] = []
    private var metadata: [SearchResult] = []
    private var fastFiles: [SearchResult] = []
    private var generation = 0
    private var metadataPending = false
    private var fastPending = false
    private let worker = DispatchQueue(label: "SpotFast.fsearch", qos: .userInitiated)
    private var fastBusy = false
    private var preferredApps: [String: URL] = [:]
    var input: String { String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1024)) }
    var selectedResult: SearchResult? { results.indices.contains(selected) ? results[selected] : nil }
    var isEmptyQuery: Bool { input.isEmpty }
    var isPinned: Bool { selectedResult?.fileURL.map { settings.pinnedPaths.contains($0.standardizedFileURL.path) } ?? false }

    init(settings: SettingsStore, usage: UsageStore) {
        self.settings = settings; self.usage = usage
        refreshApps()
    }
    func refreshApps() {
        Task {
            let found = await Task.detached(priority: .utility) {
                let roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices/Applications", NSHomeDirectory() + "/Applications"]
                var paths = Set<URL>()
                for root in roots {
                    // macOS marks Safari's top-level app link hidden. Include
                    // installed bundles before traversing non-hidden subfolders.
                    for url in (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "app" {
                        paths.insert(url)
                    }
                    guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                        includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                    for case let url as URL in enumerator {
                        if url.pathExtension == "app" { paths.insert(url); enumerator.skipDescendants() }
                    }
                }
                let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
                if FileManager.default.fileExists(atPath: finder.path) { paths.insert(finder) }
                return paths.sorted { $0.path < $1.path }
            }.value
            apps = found
            preferredApps = [:]
            for url in found {
                let key = url.lastPathComponent.lowercased()
                if preferredApps[key] == nil { preferredApps[key] = url }
            }
            schedule(resetSelection: false)
        }
    }
    func beginSession() {
        active = true
        userNavigated = false; showActions = false; showPreview = false; notice = nil
        showHome = false
        if !settings.rememberQuery { text = ""; scope = .all }
        schedule(resetSelection: true)
    }
    func suspend() {
        active = false
        generation += 1; debounce?.cancel(); stopMetadata()
        metadataPending = false; fastPending = false; searching = false; showActions = false
    }
    func settingsChanged() { schedule(resetSelection: false) }
    private func schedule(resetSelection: Bool) {
        generation += 1; debounce?.cancel(); stopMetadata()
        metadataPending = false; fastPending = false
        if resetSelection { userNavigated = false; showActions = false; selected = 0 }
        // Retain still-relevant filename rows while the next provider response arrives.
        metadata = settings.useMetadata && !input.isEmpty ? metadata.filter { Matcher.score($0.title, query: input) != nil } : []
        fastFiles = settings.useFSearch && !input.isEmpty ? fastFiles.filter { Matcher.score($0.title, query: input) != nil } : []
        notice = nil
        local = localResults(input); merge()
        guard active, !input.isEmpty, scope != .applications else { searching = false; return }
        let token = generation
        metadataPending = settings.useMetadata
        fastPending = settings.useFSearch
        searching = metadataPending || fastPending
        debounce = Task {
            // Local answers are immediate. Disk-backed providers coalesce rapid typing.
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled, token == generation else { return }
            if settings.useFSearch { startFSearch(input, token: token) }
            if settings.useMetadata { startMetadata(input, token: token) }
        }
    }
    private func localResults(_ input: String) -> [SearchResult] {
        if input.isEmpty { return homeResults() }
        var rows: [SearchResult] = []
        if scope == .all {
            if settings.useCalculator, let value = Calculator.evaluate(input) {
                let answer = String(format: "%.12g", value)
                rows.append(SearchResult(id: "calc", title: answer, subtitle: input, kind: .calculation, action: .copy(answer), score: 2000, section: "Answer"))
            }
            if settings.useCalculator, let answer = Converter.convert(input) {
                rows.append(SearchResult(id: "convert", title: answer, subtitle: input, kind: .conversion, action: .copy(answer), score: 2000, section: "Answer"))
            }
            if let score = Matcher.score("SpotFast Settings", query: input), input.count >= 3 {
                rows.append(SearchResult(id: "settings", title: "SpotFast Settings", subtitle: "Make it yours", kind: .settings, action: .settings, score: Double(score) - 50))
            }
            if settings.useDictionary, input.lowercased().hasPrefix("define ") {
                let word = String(input.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                var parts = URLComponents(); parts.scheme = "dict"; parts.host = word
                if !word.isEmpty, let url = parts.url {
                    rows.append(SearchResult(id: "dictionary", title: "Define \(word)", subtitle: "Dictionary", kind: .dictionary, action: .open(url), score: 1900, section: "Answer"))
                }
            }
        }
        if scope != .files {
            rows += apps.compactMap { url -> SearchResult? in
                guard let score = ResultRanking.applicationScore(url.deletingPathExtension().lastPathComponent, query: input) else { return nil }
                var result = fileResult(url, section: "Applications")
                result.score = score
                return result
            }
        }
        let expanded = (input as NSString).expandingTildeInPath
        if scope != .applications, expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) {
            var item = fileResult(URL(fileURLWithPath: expanded)); item.score = 1600
            rows.append(item)
        }
        if scope == .all, let url = URL(string: input), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            rows.append(SearchResult(id: "url", title: input, subtitle: "Open website", kind: .web, action: .open(url), score: 1500))
        }
        if scope == .all, settings.useWeb, let url = settings.webEngine.url(query: input) {
            rows.append(SearchResult(id: "web", title: "Search \(settings.webEngine.title)", subtitle: input, kind: .web, action: .open(url), score: -1000, section: "Web"))
        }
        return rows
    }
    private func homeResults() -> [SearchResult] {
        var rows: [SearchResult] = []
        for path in settings.pinnedPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var item = fileResult(URL(fileURLWithPath: path), section: "Pinned"); item.score = 3000
            rows.append(item)
        }
        if settings.learnUsage {
            for (i, record) in usage.records.prefix(8).enumerated() {
                guard let url = URL(string: record.url), url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { continue }
                var item = fileResult(url, section: "Recent"); item.score = 2000 - Double(i)
                rows.append(item)
            }
        }
        let familiar = ["Finder", "Safari", "Notes", "Mail", "Terminal", "System Settings"]
        let defaults = familiar.compactMap { title in apps.first { $0.deletingPathExtension().lastPathComponent == title } }
        for (i, url) in (defaults.isEmpty ? Array(apps.prefix(6)) : defaults).enumerated() {
            var item = fileResult(url, section: "Applications"); item.score = 1000 - Double(i)
            rows.append(item)
        }
        return rows
    }
    private func startMetadata(_ input: String, token: Int) {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        q.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@ OR kMDItemTextContent CONTAINS[cd] %@", input, input)
        q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        q.notificationBatchingInterval = 0.15; query = q
        for name in [Notification.Name.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, token == self.generation, let q = self.query else { return }
                    q.disableUpdates()
                    var found: [SearchResult] = []
                    for i in 0..<min(q.resultCount, 45) {
                        guard let item = q.result(at: i) as? NSMetadataItem, let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
                        var result = self.fileResult(URL(fileURLWithPath: path), folder: item.value(forAttribute: NSMetadataItemContentTypeKey) as? String == "public.folder")
                        result.score = Double(Matcher.score(result.title, query: input) ?? 200) - 25
                        found.append(result)
                    }
                    self.metadata = found; self.merge(); q.enableUpdates()
                    if note.name == .NSMetadataQueryDidFinishGathering {
                        self.metadataPending = false; self.updateSearching(); self.stopMetadata()
                    }
                }
            })
        }
        if !q.start() { metadataPending = false; updateSearching(); stopMetadata() }
    }
    private func stopMetadata() {
        query?.stop(); query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers = []
    }
    private func startFSearch(_ input: String, token: Int) {
        guard !fastBusy else { return } // The in-flight request will pick up the latest generation.
        fastBusy = true
        let socket = NSHomeDirectory() + "/Library/Application Support/SpotFast/FSearch/fsearch.sock"
        worker.async { [weak self] in
            let response = Result { try FSearchClient.search(input, socketPath: socket) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fastBusy = false
                guard token == self.generation else {
                    if self.active, self.settings.useFSearch, self.scope != .applications, !self.input.isEmpty {
                        self.startFSearch(self.input, token: self.generation)
                    }
                    return
                }
                self.fastPending = false
                switch response {
                case .success(let hits):
                    self.fastFiles = hits.enumerated().map { index, hit in
                        var item = self.fileResult(URL(fileURLWithPath: hit.path), folder: hit.kind == "dir")
                        item.score = Double(Matcher.score(item.title, query: input) ?? (500 - min(index, 99)))
                        return item
                    }
                case .failure(let error):
                    if case FSearchClient.Failure.backend(let reason) = error, reason.hasPrefix("indexing:") {
                        self.notice = "Building your file index. Apps and document search are ready."
                    } else {
                        self.notice = self.settings.useMetadata ? "Filename search is unavailable. Document search is still on." : "Filename search is unavailable. Open Settings to check the index."
                    }
                }
                self.updateSearching(); self.merge()
            }
        }
    }
    private func updateSearching() { searching = metadataPending || fastPending }
    private func fileResult(_ source: URL, folder: Bool = false, section: String = "Files") -> SearchResult {
        let app = source.pathExtension == "app" && !source.deletingLastPathComponent().pathComponents.contains(where: { $0.hasSuffix(".app") })
        let url = app ? (preferredApps[source.lastPathComponent.lowercased()] ?? source) : source
        let path = url.standardizedFileURL.path
        let id = app ? "app:" + url.lastPathComponent.lowercased() : path
        let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return SearchResult(id: id, title: app ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent,
            subtitle: app ? "Application" : parent, kind: app ? .application : folder ? .folder : .file,
            action: .open(url), section: app && section == "Files" ? "Applications" : section)
    }
    private func accepted(_ item: SearchResult) -> Bool {
        if scope == .applications && item.kind != .application { return false }
        if scope == .files && item.kind != .file && item.kind != .folder { return false }
        if let url = item.fileURL {
            if PathExclusion.contains(url.path, roots: settings.excludedFolders) { return false }
            if !settings.showHiddenFiles && url.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "/" }) { return false }
        }
        return true
    }
    private func merge() {
        let previousID = selectedResult?.id
        var winners: [String: SearchResult] = [:]
        for var item in local + fastFiles + metadata where accepted(item) {
            if !isEmptyQuery {
                if let url = item.fileURL {
                    let pathQuery = ResultRanking.hasFileIntent(input)
                    // Preserve the intentional existing-path result above search hits.
                    if item.score != 1600 {
                        if item.kind == .application {
                            guard let score = ResultRanking.applicationScore(item.title, query: input) else { continue }
                            item.score = score
                            if pathQuery { item.score = min(item.score, 850) }
                        } else if let score = ResultRanking.fileNameScore(item.title, query: input) {
                            item.score = score
                        } else {
                            // Path/content matches and backend-only fuzzy matches
                            // stay below clear name matches, including retained rows.
                            item.score = min(item.score, 200)
                        }
                    }
                    let penalty = ResultRanking.pathPenalty(url.path, query: input, filesOnly: scope == .files, application: item.kind == .application)
                    if item.score != 1600 { item.score -= penalty }
                }
                let pinned = item.fileURL.map { settings.pinnedPaths.contains($0.standardizedFileURL.path) } ?? false
                item.score = ResultRanking.personalized(item.score, usage: settings.learnUsage ? usage.boost(id: item.id) : 0, pinned: pinned)
            }
            if winners[item.id] == nil || item.score > winners[item.id]!.score { winners[item.id] = item }
        }
        let ranked = winners.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhsDepth = $0.fileURL?.pathComponents.count ?? 0
            let rhsDepth = $1.fileURL?.pathComponents.count ?? 0
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            if $0.title.count != $1.title.count { return $0.title.count < $1.title.count }
            return $0.id < $1.id
        }
        if userNavigated {
            let order = results.map(\.id)
            let existing = order.compactMap { winners[$0] }
            let retained = Set(existing.map(\.id))
            results = Array((existing + ranked.filter { !retained.contains($0.id) }).prefix(60))
        } else {
            // Keep the web action reachable even with a full file candidate pool.
            let web = ranked.first { $0.id == "web" }
            results = Array(ranked.filter { $0.id != "web" }.prefix(web == nil ? 60 : 59))
            if let web { results.append(web) }
        }
        selected = SelectionPolicy.resolve(previousID: previousID, previousIndex: selected, userNavigated: userNavigated, ids: results.map(\.id))
    }
    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        userNavigated = true; selected = index
    }
    func move(_ delta: Int) {
        if isEmptyQuery && !showHome { showHome = true; return }
        select(max(0, min(results.count - 1, selected + delta)))
    }
    func activate(_ item: SearchResult? = nil) {
        guard item != nil || !isEmptyQuery || showHome else { return }
        guard let item = item ?? selectedResult else { return }
        switch item.action {
        case .open(let url):
            guard NSWorkspace.shared.open(url) else { notice = "Couldn't open \(item.title)."; return }
            if settings.learnUsage { usage.record(item) }
            if url.isFileURL { didOpen?(url) }
        case .copy(let value):
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        case .settings: openSettings?(); return
        }
        dismiss?()
    }
    func reveal(_ item: SearchResult? = nil) {
        guard let url = (item ?? selectedResult)?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url]); dismiss?()
    }
    func copyPath(_ item: SearchResult? = nil) {
        guard let url = (item ?? selectedResult)?.fileURL else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
        notice = "Path copied"; showActions = false
    }
    func pin(_ item: SearchResult? = nil) {
        guard let url = (item ?? selectedResult)?.fileURL else { return }
        settings.togglePin(url); showActions = false
    }
    func clearHistory() { usage.clear(); settingsChanged() }
}
