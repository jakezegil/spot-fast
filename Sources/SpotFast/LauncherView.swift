import AppKit
import SwiftUI
import QuickLookUI

struct SearchField: NSViewRepresentable {
    @ObservedObject var model: SearchModel
    var command: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 23, weight: .regular)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search apps, files, and contacts",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                         .font: NSFont.systemFont(ofSize: 23, weight: .regular)])
        field.textColor = .labelColor; field.delegate = context.coordinator
        field.setAccessibilityLabel("Search apps, files, and contacts")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .launcherShown, object: nil, queue: .main) { [weak field] _ in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            (field.currentEditor() as? NSTextView)?.selectAll(nil)
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != model.text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            field.stringValue = model.text
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        weak var field: NSTextField?
        var observer: NSObjectProtocol?
        init(_ parent: SearchField) { self.parent = parent }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
        func controlTextDidChange(_ notification: Notification) {
            if let field { parent.model.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            let name = NSStringFromSelector(selector)
            guard ["moveDown:", "moveUp:", "insertNewline:", "cancelOperation:", "insertTab:", "insertBacktab:"].contains(name) else { return false }
            parent.command(name); return true
        }
    }
}

@MainActor final class IconCache: ObservableObject {
    private let cache = NSCache<NSString, NSImage>()
    init() { cache.countLimit = 300 }
    func icon(_ url: URL) -> NSImage {
        if let image = cache.object(forKey: url.path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: url.path as NSString); return image
    }
}

struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 4))
    }
}

struct ResultIcon: View {
    let result: SearchResult
    @ObservedObject var icons: IconCache
    var size: CGFloat = 30
    var body: some View {
        Group {
            if let url = result.fileURL {
                Image(nsImage: icons.icon(url)).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: result.symbol).font(.system(size: size * 0.65, weight: .medium))
                    .foregroundStyle(result.kind == .calculation || result.kind == .conversion ? Color.accentColor : Color.secondary)
                    .frame(width: size, height: size)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
        }.frame(width: size, height: size)
    }
}

struct LauncherView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var settings: SettingsStore
    @StateObject private var icons = IconCache()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    var command: (String) -> Void
    var onLayout: (CGFloat) -> Void
    private var expanded: Bool { !model.isEmptyQuery || model.showHome || model.scope == .contacts }
    private var rowHeight: CGFloat { settings.compactRows ? 44 : 54 }
    private var listHeight: CGFloat { min(8, CGFloat(model.results.count)) * rowHeight + 30 }
    private var contentHeight: CGFloat { expanded ? max(110, listHeight) : 0 }
    private var height: CGFloat { 66 + (expanded ? 43 + contentHeight + 34 + (model.notice != nil ? 31 : 0) : 0) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "magnifyingglass").font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                SearchField(model: model, command: command).frame(height: 34)
                if model.searching { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 16) }
                Button { model.openSettings?() } label: { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("Settings · ⌘,")
                    .accessibilityLabel("Open settings")
            }.padding(.horizontal, 20).frame(height: 66)
                .background(Color(nsColor: .windowBackgroundColor))
            if expanded {
                Divider()
                HStack(spacing: 5) {
                    ForEach(SearchScope.allCases) { scope in
                        Button { model.scope = scope } label: {
                            HStack(spacing: 5) { Image(systemName: scope.symbol); Text(scope.title) }
                                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                                .background(model.scope == scope ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                                .foregroundStyle(model.scope == scope ? Color.accentColor : Color.secondary)
                        }.buttonStyle(.plain).accessibilityAddTraits(model.scope == scope ? .isSelected : [])
                    }
                    Spacer()
                    Text("Tab to switch").font(.system(size: 10)).foregroundStyle(.tertiary)
                    if model.selectedResult?.fileURL != nil {
                        Button { model.showPreview.toggle() } label: { Image(systemName: "sidebar.right") }
                            .buttonStyle(.plain).foregroundStyle(model.showPreview ? Color.accentColor : Color.secondary)
                            .help("Preview · ⌘P")
                    }
                }.padding(.horizontal, 15).frame(height: 42)
                HStack(spacing: 0) {
                    resultList.frame(maxWidth: .infinity)
                    if model.showPreview {
                        Divider()
                        PreviewPane(result: model.selectedResult, icons: icons).frame(width: 275)
                    }
                }.frame(height: contentHeight)
                if let notice = model.notice {
                    HStack(spacing: 7) {
                        Image(systemName: "info.circle"); Text(notice).lineLimit(1)
                        Spacer()
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 31)
                }
                Divider()
                HStack(spacing: 8) {
                    Text(model.results.isEmpty ? "No matches" : "\(model.results.count) results")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    if let result = model.selectedResult {
                        KeyCap(text: "↵"); Text(result.verb).font(.system(size: 10)).foregroundStyle(.secondary)
                        if result.fileURL != nil {
                            KeyCap(text: "⌘↵"); Text("Reveal").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Button { model.showActions.toggle() } label: {
                            HStack(spacing: 5) { Text("Actions"); KeyCap(text: "⌘K") }
                        }.font(.system(size: 10)).buttonStyle(.plain)
                            .popover(isPresented: $model.showActions, arrowEdge: .bottom) { actions }
                    }
                }.padding(.horizontal, 17).frame(height: 33)
            }
        }.frame(width: 720)
            .onAppear { onLayout(height) }
            .onChange(of: height) { value in onLayout(value) }
            .onChange(of: model.selected) { _ in announceSelection() }
    }
    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.isEmptyQuery {
                        HStack {
                            Text(model.scope == .contacts ? "Contacts" : model.results.contains { $0.section == "Recent" } ? "Pinned & recent" : "Your apps")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("↑ ↓ to choose").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 12).frame(height: 25)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        row(result, index: index).id(result.id)
                    }
                    if model.results.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text(model.searching ? "Searching your Mac…" : "No matches yet").font(.system(size: 13, weight: .medium))
                            if model.scope == .contacts {
                                ContactsAccessView(store: model.contacts, enabled: settings.useContacts)
                            } else {
                                Text("Try an app, file, contact, or calculation.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(20)
                    }
                }.padding(.horizontal, 7).padding(.vertical, 5)
            }.onChange(of: model.selected) { index in
                if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
            }
        }
    }
    private func row(_ result: SearchResult, index: Int) -> some View {
        let selected = model.selected == index
        return HStack(spacing: 11) {
            ResultIcon(result: result, icons: icons, size: settings.compactRows ? 26 : 31)
            VStack(alignment: .leading, spacing: 3) {
                highlighted(result.title).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1)
                Text(result.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if result.fileURL.map({ settings.pinnedPaths.contains($0.standardizedFileURL.path) }) == true {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            else if index < 9 { Text("⌘\(index + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary) }
        }.padding(.horizontal, 12).frame(height: rowHeight)
            .background(selected ? Color.accentColor.opacity(contrast == .increased ? 0.28 : 0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .leading) {
                if selected { RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2, height: 19).padding(.leading, 3) }
            }
            .contentShape(Rectangle()).onTapGesture { model.select(index); model.activate(result) }
            .contextMenu { actionButtons(result) }
            .onDrag {
                if let url = result.fileURL, let provider = NSItemProvider(contentsOf: url) { return provider }
                return NSItemProvider()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.title), \(result.subtitle)")
            .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { model.activate(result) }
    }
    private func highlighted(_ title: String) -> Text {
        guard !model.input.isEmpty, let range = title.range(of: model.input, options: [.caseInsensitive, .diacriticInsensitive]) else { return Text(title) }
        return Text(String(title[..<range.lowerBound])) + Text(String(title[range])).bold() + Text(String(title[range.upperBound...]))
    }
    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let result = model.selectedResult {
                Text(result.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Divider(); actionButtons(result)
            }
        }.buttonStyle(.plain).padding(16).frame(width: 245)
    }
    @ViewBuilder private func actionButtons(_ result: SearchResult) -> some View {
        Button(result.verb) { model.activate(result) }
        if result.kind == .contact {
            ForEach(Array(result.contactAddresses.enumerated()), id: \.offset) { _, address in
                Button("Message " + address.label + " · " + address.value) { model.message(address) }
            }
        }
        if result.fileURL != nil {
            Button("Reveal in Finder") { model.reveal(result) }
            Button("Preview") { model.showPreview = true; model.showActions = false }
            Button("Copy path") { model.copyPath(result) }
            Button(settings.pinnedPaths.contains(result.fileURL!.path) ? "Unpin" : "Pin to launcher") { model.pin(result) }
        }
    }
    private func announceSelection() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let result = model.selectedResult else { return }
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: result.title, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

struct QuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL; view.refreshPreviewItem() }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

struct PreviewPane: View {
    let result: SearchResult?
    @ObservedObject var icons: IconCache
    var body: some View {
        if let result {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    ResultIcon(result: result, icons: icons, size: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        Text(result.kind == .application ? "Application" : result.kind == .folder ? "Folder" : "Preview")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if let url = result.fileURL {
                    if result.kind != .application && result.kind != .folder {
                        QuickLookView(url: url).id(url).frame(maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Divider()
                    Text((url.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 10)).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(4).truncationMode(.middle)
                } else {
                    Text(result.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else { Text("Choose a result to preview").font(.system(size: 12)).foregroundStyle(.secondary) }
    }
}
