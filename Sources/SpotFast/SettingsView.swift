import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, search, appearance, privacy, index, about
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .search: return "magnifyingglass"
        case .appearance: return "paintbrush"
        case .privacy: return "hand.raised"
        case .index: return "externaldrive"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: SearchModel
    @ObservedObject var health: ServiceHealth
    @State private var page: SettingsPage = .general
    @State private var cleared = false
    @State private var restartConfirmation = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 24)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SpotFast").font(.system(size: 15, weight: .semibold))
                        Text("Make it yours").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 24)
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.title, systemImage: item.symbol).font(.system(size: 12, weight: page == item ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 9)
                            .background(page == item ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
                Text("⌘, opens settings").font(.system(size: 10)).foregroundStyle(.tertiary).padding(12)
            }.padding(.horizontal, 10).frame(width: 170).background(.thinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title).font(.system(size: 23, weight: .semibold)).padding(.horizontal, 25).padding(.top, 25).padding(.bottom, 10)
                Form { content }.formStyle(.grouped).scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity)
        }.frame(width: 750, height: 560)
            .onAppear { health.refresh() }
            .onChange(of: page) { _ in if page == .index { health.refresh() } }
            .confirmationDialog("Restart the filename service?", isPresented: $restartConfirmation, titleVisibility: .visible) {
                Button("Restart service") { health.restart() }
            } message: { Text("The saved index is retained. Filename results may briefly be unavailable.") }
    }
    @ViewBuilder private var content: some View {
        switch page {
        case .general:
            Section {
                Picker("Global shortcut", selection: $settings.commandSpace) {
                    Text("Command–Space").tag(true); Text("Option–Space").tag(false)
                }
                if let error = settings.shortcutError { Text(error).foregroundStyle(.red).font(.caption) }
                Toggle("Keep query when reopening", isOn: $settings.rememberQuery)
            } footer: { Text("Typing replaces a retained query. The shortcut opens SpotFast on the display with your pointer.") }
            Section {
                LabeledContent("Login agents", value: "Launcher + filename service")
                Button("Open Login Items…") { open("x-apple.systempreferences:com.apple.LoginItems-Settings.extension") }
                Button("Open keyboard shortcuts…") { open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension") }
            } header: { Text("Startup") } footer: { Text("Both agents are installed for your user. Manage their startup permissions in macOS System Settings.") }
            Section("Keyboard") {
                shortcut("Actions", "⌘K"); shortcut("Preview", "⌘P / ⌘Y")
                shortcut("Reveal in Finder", "⌘↵"); shortcut("Copy file path", "⌥⌘C")
                shortcut("Open result 1–9", "⌘1–9"); shortcut("Switch category", "Tab")
            }
        case .search:
            Section {
                Toggle("Fast filename search", isOn: $settings.useFSearch)
                Toggle("Document text & metadata", isOn: $settings.useMetadata)
                Toggle("Calculator & conversions", isOn: $settings.useCalculator)
                Toggle("Dictionary lookups", isOn: $settings.useDictionary)
                Toggle("Web search action", isOn: $settings.useWeb)
                if settings.useWeb { Picker("Search engine", selection: $settings.webEngine) { ForEach(WebEngine.allCases) { Text($0.title).tag($0) } } }
            } header: { Text("Sources") } footer: { Text("Web queries are sent only when you choose the web result. Turning off filename results does not stop its background service.") }
            Section("File results") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            }
            Section {
                ForEach(settings.excludedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer(); Button { settings.excludedFolders.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                Button("Add folder…") { chooseFolder() }
            } header: { Text("Hide results from folders") } footer: { Text("Exclusions hide results across all sources and remove those items from recent history. They do not delete entries from the filename index.") }
        case .appearance:
            Section {
                Picker("Appearance", selection: $settings.appearance) { ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) } }
                Toggle("Compact result rows", isOn: $settings.compactRows)
            } header: { Text("Style") } footer: { Text("System appearance follows macOS. Transparency and motion follow your accessibility preferences.") }
            Section("Launcher") {
                Text("A quiet search bar expands only when you type or press ↓. Recent items stay hidden when the launcher first opens.")
                Text("File previews open on demand with ⌘P or ⌘Y.").foregroundStyle(.secondary)
            }
        case .privacy:
            Section {
                Toggle("Remember opened apps and files", isOn: $settings.learnUsage)
                Button(cleared ? "History cleared" : "Clear local history") { model.clearHistory(); cleared = true }
            } header: { Text("Local history") } footer: { Text("History stores only the last 100 opened file or app locations for up to 90 days, timestamps, and open counts on this Mac. Search queries, web URLs, file contents, and calculations are never recorded. Turning history off also removes its ranking boost.") }
            Section("Permissions") {
                LabeledContent("Filename service", value: "Ordinary user permissions")
                LabeledContent("Full Disk Access", value: "Not requested")
                LabeledContent("Protected folders", value: "Excluded from filename indexing")
                Text("Document search uses Apple's existing metadata index and macOS privacy controls.").foregroundStyle(.secondary)
            }
            Section("Pinned items") {
                Text("Pinned app and file paths are stored in your local preferences. Remove a pin through the launcher's action menu.").foregroundStyle(.secondary)
            }
        case .index:
            Section("Filename index") {
                LabeledContent("Status") { HStack(spacing: 6) { Circle().fill(health.error == nil ? Color.green : Color.orange).frame(width: 6, height: 6); Text(health.summary) } }
                if let status = health.status {
                    LabeledContent("Entries", value: status.entries.formatted())
                    LabeledContent("Folders", value: status.dirs.formatted())
                    LabeledContent("Index size", value: ByteCountFormatter.string(fromByteCount: Int64(status.index_bytes), countStyle: .file))
                }
                if let error = health.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh status") { health.refresh() }.disabled(health.checking)
                    Button(health.restarting ? "Restarting…" : "Restart service…") { restartConfirmation = true }.disabled(health.restarting)
                }
            }
            Section("Why a separate service?") {
                Text("The filename service keeps its large index and filesystem work outside the launcher. SpotFast can keep opening apps and answering calculations if that service restarts.")
                Text("Both processes use your account. Process separation contains crashes and memory use; it is not a separate privilege boundary.").foregroundStyle(.secondary)
            }
            Section {
                Button("Reveal local data folder") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/SpotFast")) }
            }
        case .about:
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "sparkle.magnifyingglass").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("SpotFast").font(.system(size: 19, weight: .semibold))
                        Text("Search your Mac. Keep your flow.").foregroundStyle(.secondary)
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0")").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 8)
            }
            Section("Built with") { Text("Native SwiftUI + AppKit, Apple's metadata search, and a locally hardened FSearch helper.") }
            Section {
                Button("Copy diagnostics") { copyDiagnostics() }
                Button("View FSearch source") { open("https://github.com/noahdunnagan/fsearch") }
            } footer: { Text("Diagnostics contain versions, settings flags, and index counts. They do not include queries, history, or result paths. Nothing is uploaded automatically.") }
        }
    }
    private func shortcut(_ label: String, _ keys: String) -> some View { LabeledContent(label) { KeyCap(text: keys) } }
    private func open(_ string: String) { if let url = URL(string: string) { NSWorkspace.shared.open(url) } }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        panel.prompt = "Hide results"; panel.message = "Choose folders to exclude from launcher results."
        if panel.runModal() == .OK {
            let added = panel.urls.map { $0.standardizedFileURL.path }
            settings.excludedFolders = Array(Set(settings.excludedFolders + added)).sorted()
        }
    }
    private func copyDiagnostics() {
        let text = "SpotFast \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.2.0")\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString)\nShortcut: \(settings.shortcutLabel)\nFilename search: \(settings.useFSearch)\nMetadata search: \(settings.useMetadata)\nIndex: \(health.summary)\nEntries: \(health.status?.entries ?? 0)\nIndex bytes: \(health.status?.index_bytes ?? 0)\n"
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
