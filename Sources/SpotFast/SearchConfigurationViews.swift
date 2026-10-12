import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SpotFastCore

struct ApplicationAliasesView: View {
    @ObservedObject var settings: SettingsStore
    @State private var name = ""
    @State private var target: URL?
    @State private var error: String?
    private var normalized: String { ApplicationAlias.normalized(name) }
    var body: some View {
        Section {
            ForEach(settings.applicationAliases) { alias in
                HStack {
                    Text(alias.name).fontWeight(.medium)
                    Spacer()
                    Text(URL(fileURLWithPath: alias.applicationPath).deletingPathExtension().lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                    Button { settings.applicationAliases.removeAll { $0.id == alias.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            TextField("Alias, for example browser", text: $name)
            HStack {
                Button(target?.deletingPathExtension().lastPathComponent ?? "Choose application…") { chooseApp() }
                Spacer()
                Button("Add alias") { add() }.disabled(target == nil || normalized.isEmpty || settings.applicationAliases.count >= 128)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Text("Application aliases") } footer: {
            Text("An exact alias takes priority in All and Apps. Aliases stay local. Apps also match small spelling errors such as chorme.")
        }
    }
    private func chooseApp() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = false; picker.canChooseFiles = true
        picker.allowedContentTypes = [.applicationBundle]; picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.prompt = "Choose application"
        if picker.runModal() == .OK { target = picker.url }
    }
    private func add() {
        guard let target else { return }
        let alias = ApplicationAlias(name: name, applicationPath: target.path)
        guard alias.isValid else { error = "Use up to 32 letters, numbers, spaces, hyphens, or underscores."; return }
        guard !settings.applicationAliases.contains(where: { ApplicationAlias.normalized($0.name) == normalized }) else {
            error = "That alias already exists."; return
        }
        settings.applicationAliases.append(alias); name = ""; self.target = nil; error = nil
    }
}

struct FileCoverageView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var index: SelectedFolderIndex
    @State private var error: String?
    private var regularProviders: String {
        let names = [settings.useFSearch ? "FSearch" : nil, settings.useMetadata ? "macOS metadata" : nil].compactMap { $0 }
        return names.isEmpty ? "Selected folders below" : names.joined(separator: " + ")
    }
    var body: some View {
        Section {
            LabeledContent("Regular local files", value: regularProviders)
            LabeledContent("Desktop, Documents & Downloads", value: settings.useMetadata ? "macOS metadata; selected folders below" : "Selected folders below")
            LabeledContent("Cloud folders & external drives", value: settings.useMetadata ? "Available macOS metadata; selected folders below" : "Selected folders below")
            Text("macOS metadata depends on Apple's index and your privacy settings. It does not guarantee every file is indexed.").font(.caption).foregroundStyle(.secondary)
        } header: { Text("File search coverage") }
        Section {
            ForEach(settings.selectedFolders) { folder in
                let status = index.statuses.first { $0.id == folder.id }
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder.name).fontWeight(.medium)
                        Text(index.scanning ? "Indexing names…" : status?.detail ?? "Waiting to index").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { settings.selectedFolders.removeAll { $0.id == folder.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Add folder to search…") { choose() }.disabled(settings.selectedFolders.count >= 16)
                Button("Refresh folder names") { index.refresh() }.disabled(index.scanning || settings.selectedFolders.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Text("Selected-folder filename search") } footer: {
            Text("Choose Desktop, Documents, Downloads, a cloud folder, or a mounted drive to add filename coverage. Access is limited to folders you select. This reads names, skips package contents, and keeps its index in memory. It refreshes every minute, with a 100,000-name total limit. Partial or unavailable coverage is shown above.")
        }
    }
    private func choose() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.prompt = "Add to search"; picker.message = "SpotFast will index names in these folders using the access you grant here."
        guard picker.runModal() == .OK else { return }
        for url in picker.urls {
            guard FolderCatalog.allowsRoot(url) else { error = "Choose a specific folder or mounted drive, rather than the entire home or filesystem."; continue }
            guard settings.selectedFolders.count < 16 else { break }
            if settings.selectedFolders.contains(where: { (try? $0.resolve().standardizedFileURL.path) == url.standardizedFileURL.path }) { continue }
            do { settings.selectedFolders.append(try SelectedFolder(url: url)); error = nil }
            catch { self.error = "Couldn't retain access. Choose the folder again: \(error.localizedDescription)" }
        }
    }
}
