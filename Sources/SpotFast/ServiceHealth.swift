import AppKit
import Combine
import SpotFastCore

@MainActor final class ServiceHealth: ObservableObject {
    @Published private(set) var status: FSearchStatus?
    @Published private(set) var error: String?
    @Published private(set) var checking = false
    @Published private(set) var restarting = false
    private let queue = DispatchQueue(label: "SpotFast.health", qos: .utility)
    var summary: String { error != nil ? "Unavailable" : status == nil ? "Checking…" : status!.entries == 0 ? "Indexing…" : "Ready" }
    func refresh() {
        guard !checking else { return }; checking = true
        let path = NSHomeDirectory() + "/Library/Application Support/SpotFast/FSearch/fsearch.sock"
        queue.async { [weak self] in
            let response = Result { try FSearchClient.status(socketPath: path) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.checking = false
                switch response {
                case .success(let status): self.status = status; self.error = nil
                case .failure(let error): self.status = nil; self.error = error.localizedDescription
                }
            }
        }
    }
    func restart() {
        guard !restarting else { return }; restarting = true
        queue.async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = ["kickstart", "-k", "gui/\(getuid())/local.spotfast.fsearch"]
            task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
            let response = Result { try task.run(); task.waitUntilExit(); return task.terminationStatus }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.restarting = false
                if case .success(0) = response {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
                } else { self.error = "Couldn't restart the filename service. Check Login Items in System Settings." }
            }
        }
    }
}
