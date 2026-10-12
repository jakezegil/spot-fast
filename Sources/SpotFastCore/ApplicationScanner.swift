import Foundation
import Dispatch
import Darwin

public enum ApplicationScanner {
    public struct Snapshot: Sendable { public let applications: [URL]; public let directories: [URL] }
    public static func scan(roots: [URL]) -> Snapshot {
        var applications = Set<URL>(), directories = Set<URL>()
        func include(_ url: URL) {
            guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path) else { return }
            applications.insert(url)
        }
        for root in roots {
            guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            directories.insert(root)
            children.forEach(include)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" { include(url); enumerator.skipDescendants() }
                else if directories.count < 128, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { directories.insert(url) }
            }
        }
        return Snapshot(applications: applications.sorted { $0.path < $1.path }, directories: directories.sorted { $0.path < $1.path })
    }
}

@MainActor public final class DirectoryMonitor {
    public var changed: (() -> Void)?
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending: DispatchWorkItem?
    public init() {}
    public func watch(_ directories: [URL]) {
        let paths = Set(directories.prefix(128).map(\.path))
        for path in Array(sources.keys) where !paths.contains(path) { sources.removeValue(forKey: path)?.cancel() }
        for path in paths where sources[path] == nil {
            let fd = open(path, O_EVTONLY | O_CLOEXEC)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let source, !source.data.intersection([.rename, .delete]).isEmpty {
                        self.sources.removeValue(forKey: path)?.cancel()
                    }
                    self.pending?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.changed?() }
                    self.pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
                }
            }
            source.setCancelHandler { close(fd) }; sources[path] = source; source.resume()
        }
    }
    deinit { pending?.cancel(); sources.values.forEach { $0.cancel() } }
}
