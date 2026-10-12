import AppKit
import Combine
import SpotFastCore

@MainActor final class SelectedFolderIndex: ObservableObject {
    struct Status: Identifiable { let id: UUID; let name: String; let path: String?; let detail: String }
    @Published private(set) var statuses: [Status] = []
    @Published private(set) var scanning = false
    @Published private(set) var entries: [FolderEntry] = []
    var changed: (() -> Void)?
    private var folders: [SelectedFolder] = []
    private var excluded: [String] = []
    private var hidden = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
    }
    func configure(_ folders: [SelectedFolder], excluded: [String], hidden: Bool) {
        guard self.folders != folders || self.excluded != excluded || self.hidden != hidden else { return }
        self.folders = Array(folders.prefix(16)); self.excluded = excluded; self.hidden = hidden
        generation += 1; task?.cancel()
        entries = []; statuses = []; changed?(); refresh()
    }
    func refresh() {
        guard !folders.isEmpty, !scanning else { return }
        scanning = true
        let token = generation, folders = folders, excluded = excluded, hidden = hidden
        let worker = Task.detached(priority: .utility) { () -> ([FolderEntry], [Status]) in
            var entries: [FolderEntry] = [], statuses: [Status] = []
            for folder in folders {
                if Task.isCancelled { break }
                do {
                    let root = try folder.resolve()
                    let access = root.startAccessingSecurityScopedResource()
                    defer { if access { root.stopAccessingSecurityScopedResource() } }
                    guard FileManager.default.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile) }
                    let result = FolderCatalog.scan(root: root, excluded: excluded, hidden: hidden, limit: max(0, 100_000 - entries.count), cancelled: { Task.isCancelled })
                    entries += result.entries
                    let detail = result.limited ? "Partial index · limit reached" : result.errors > 0 ? "Partial index · some items inaccessible" : "\(result.entries.count.formatted()) names indexed"
                    statuses.append(Status(id: folder.id, name: folder.name, path: root.path, detail: detail))
                } catch {
                    statuses.append(Status(id: folder.id, name: folder.name, path: nil, detail: "Unavailable · reconnect or choose folder again"))
                }
            }
            return (entries, statuses)
        }
        task = Task {
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard token == generation else { scanning = false; task = nil; refresh(); return }
            entries = result.0; statuses = result.1; scanning = false; task = nil; changed?()
        }
    }
}
