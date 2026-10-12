import Foundation

public struct SelectedFolder: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let bookmark: Data
    public init(url: URL) throws {
        id = UUID(); name = url.lastPathComponent
        bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolve() throws -> URL {
        var stale = false
        return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
public struct FolderEntry: Equatable, Sendable {
    public let path: String
    public let directory: Bool
    public init(path: String, directory: Bool) { self.path = path; self.directory = directory }
}
public enum FolderCatalog {
    public struct Scan: Sendable { public let entries: [FolderEntry]; public let limited: Bool; public let errors: Int }
    public static func allowsRoot(_ root: URL) -> Bool {
        root.isFileURL && !["/", "/Users", "/Volumes", NSHomeDirectory()].contains(root.standardizedFileURL.path)
    }
    /// Names only. Never read file contents or follow directory symlinks.
    public static func scan(root: URL, excluded: [String], hidden: Bool, limit: Int = 100_000, cancelled: () -> Bool = { false }) -> Scan {
        var entries: [FolderEntry] = [], errors = 0, limited = false
        let options: FileManager.DirectoryEnumerationOptions = hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
        guard allowsRoot(root), !PathExclusion.contains(root.path, roots: excluded),
              let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: options, errorHandler: { _, _ in errors += 1; return true }) else {
            return Scan(entries: [], limited: false, errors: 1)
        }
        let deadline = Date().addingTimeInterval(30)
        for case let url as URL in iterator {
            if cancelled() { break }
            if entries.count >= limit || Date() > deadline { limited = true; break }
            if PathExclusion.contains(url.path, roots: excluded) { iterator.skipDescendants(); continue }
            // Do not enter a different mount inside the selected root.
            if (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true { iterator.skipDescendants(); continue }
            let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if info?.isSymbolicLink == true { iterator.skipDescendants() }
            entries.append(FolderEntry(path: url.path, directory: info?.isDirectory == true && info?.isSymbolicLink != true))
        }
        return Scan(entries: entries, limited: limited, errors: errors)
    }
    public static func search(_ query: String, entries: [FolderEntry], cancelled: () -> Bool = { false }) -> [FolderEntry] {
        var hits: [(FolderEntry, Double)] = []
        for (i, entry) in entries.enumerated() {
            if i % 256 == 0 && cancelled() { return [] }
            let name = (entry.path as NSString).lastPathComponent
            if let score = ResultRanking.fileNameScore(name, query: query) { hits.append((entry, score)) }
            else if query.contains("/"), Matcher.score(entry.path, query: query) != nil { hits.append((entry, 200)) }
        }
        return hits.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(100).map { $0.0 }
    }
}
