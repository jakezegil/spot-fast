import AppKit
import Carbon
import SwiftUI
import SpotFastCore

extension Notification.Name { static let launcherShown = Notification.Name("SpotFast.launcherShown") }

final class LauncherPanel: NSPanel {
    var shortcut: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (firstResponder as? NSTextView)?.hasMarkedText() != true, shortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = SettingsStore()
    private lazy var usage = UsageStore(persist: !smoke)
    private lazy var model = SearchModel(settings: settings, usage: usage)
    private let health = ServiceHealth()
    private var panel: LauncherPanel!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private var registeredCommandSpace: Bool?
    private var updatingSettings = false
    private var anchor: CGFloat = 0
    private let smoke = CommandLine.arguments.contains("--ui-smoke-test")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 66),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let material = NSVisualEffectView()
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        material.wantsLayer = true; material.layer?.cornerRadius = 14; material.layer?.masksToBounds = true
        let host = NSHostingView(rootView: LauncherView(model: model, settings: settings,
            command: { [weak self] in self?.command($0) }, onLayout: { [weak self] in self?.resize($0) }))
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor), host.bottomAnchor.constraint(equalTo: material.bottomAnchor)])
        panel.contentView = material; panel.delegate = self
        panel.shortcut = { [weak self] in self?.handleShortcut($0) ?? false }
        model.dismiss = { [weak self] in self?.hide() }
        model.openSettings = { [weak self] in self?.showSettings() }
        settings.changed = { [weak self] in self?.settingsChanged() }
        usage.purge(excludedFolders: settings.excludedFolders)
        makeMenus()
        if smoke { runSmokeTest(); return }
        installHotKey()
    }
    private func makeMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        add(appMenu, title: "Settings…", action: #selector(showSettings)).keyEquivalent = ","
        appMenu.addItem(.separator()); add(appMenu, title: "Quit SpotFast", action: #selector(quit)).keyEquivalent = "q"
        appItem.submenu = appMenu; main.addItem(appItem)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        edit.submenu = editMenu; main.addItem(edit); NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "magnifyingglass.circle", accessibilityDescription: "SpotFast")
        let menu = NSMenu()
        add(menu, title: "Search…", action: #selector(show))
        add(menu, title: "Settings…", action: #selector(showSettings))
        add(menu, title: "Refresh applications", action: #selector(refresh))
        menu.addItem(.separator()); add(menu, title: "Quit SpotFast", action: #selector(quit))
        statusItem.menu = menu
    }
    @discardableResult private func add(_ menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self; menu.addItem(item); return item
    }
    private func applyAppearance() {
        NSApp.appearance = settings.appearance == .system ? nil : NSAppearance(named: settings.appearance == .dark ? .darkAqua : .aqua)
    }
    private func settingsChanged() {
        guard !updatingSettings else { return }
        updatingSettings = true
        applyAppearance()
        if !smoke, registeredCommandSpace != settings.commandSpace {
            let previous = registeredCommandSpace
            if !installHotKey(), let previous {
                settings.commandSpace = previous
                _ = installHotKey()
                settings.shortcutError = "That shortcut is in use. Turn off Spotlight’s shortcut in macOS Keyboard settings first."
            }
        }
        usage.purge(excludedFolders: settings.excludedFolders)
        model.settingsChanged(); updatingSettings = false
    }
    @discardableResult private func installHotKey() -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if hotKeyHandler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
                guard let context else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { delegate.toggle() }; return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let id = EventHotKeyID(signature: 0x53504654, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(settings.commandSpace ? cmdKey : optionKey), id,
            GetApplicationEventTarget(), 0, &hotKey)
        if result == noErr { registeredCommandSpace = settings.commandSpace; settings.shortcutError = nil }
        else { settings.shortcutError = "Shortcut unavailable. Check macOS Keyboard settings." }
        let state: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "commandSpace": settings.commandSpace, "registered": result == noErr]
        let directory = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/SpotFast")
        if FileManager.default.fileExists(atPath: directory.path),
           let bytes = try? PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0) {
            try? bytes.write(to: directory.appendingPathComponent("registration.plist"), options: .atomic)
        }
        return result == noErr
    }
    @objc func show() {
        model.beginSession()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let screen {
            let frame = screen.visibleFrame
            anchor = frame.maxY - frame.height * 0.22
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: anchor - panel.frame.height))
        }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .launcherShown, object: nil)
    }
    private func resize(_ height: CGFloat) {
        guard let panel else { return }
        var frame = panel.frame
        let top = panel.isVisible && anchor != 0 ? anchor : frame.maxY
        frame.size.height = height; frame.origin.y = top - height
        panel.setFrame(frame, display: true)
    }
    private func hide() { model.suspend(); panel.orderOut(nil) }
    func toggle() { if panel.isVisible { hide() } else { show() } }
    private func command(_ name: String) {
        switch name {
        case "moveDown:": model.move(1)
        case "moveUp:": model.move(-1)
        case "insertNewline:": model.activate()
        case "insertTab:": model.scope = model.scope.next
        case "insertBacktab:": model.scope = model.scope.next.next
        case "cancelOperation:":
            if model.showActions { model.showActions = false }
            else if model.showPreview { model.showPreview = false }
            else { hide() }
        default: break
        }
    }
    private func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if key == "," { showSettings(); return true }
        if key == "k" { if model.selectedResult != nil { model.showActions.toggle() }; return true }
        if key == "p" || key == "y" { model.showPreview.toggle(); return true }
        if event.keyCode == 36 { model.reveal(); return true }
        if key == "c", flags.contains(.option) { model.copyPath(); return true }
        if let n = Int(key), (1...9).contains(n), model.results.indices.contains(n - 1) {
            model.select(n - 1); model.activate(); return true
        }
        return false
    }
    @objc private func showSettings() {
        hide()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 750, height: 560),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "SpotFast Settings"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, model: model, health: health))
            window.setFrameAutosaveName("SpotFast.Settings"); window.center(); settingsWindow = window
        }
        health.refresh(); NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func refresh() { model.refreshApps() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel, !model.showActions { hide() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
    private func runSmokeTest() {
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            model.text = "(18 + 6) / 3"
            guard model.selectedResult?.title == "8" else { fputs("Calculator UI smoke failed\n", stderr); exit(1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                panel.appearance = NSAppearance(named: .aqua)
                snapshot(panel, name: "launcher-light")
                panel.appearance = NSAppearance(named: .darkAqua)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                    snapshot(panel, name: "launcher-dark")
                    model.text = "sound"
                    guard model.selectedResult?.kind == .systemSetting,
                          model.selectedResult?.title == "Sound" else { fputs("Settings search smoke failed\n", stderr); exit(1) }
                    model.scope = .files
                    guard !model.results.contains(where: { $0.kind == .systemSetting }) else { exit(1) }
                    model.scope = .applications
                    guard model.results.allSatisfy({ $0.kind == .application }) else { exit(1) }
                    showSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                        snapshot(settingsWindow!, name: "settings")
                        print("UI smoke passed: calculator, System Settings search, scope filtering, launcher and settings rendering")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }
    private func snapshot(_ window: NSWindow, name: String) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/ui-smoke")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name + ".png"))
        try? view.dataWithPDF(inside: view.bounds).write(to: directory.appendingPathComponent(name + ".pdf"))
    }
}

if CommandLine.arguments.contains("--check-fsearch") {
    do {
        try FSearchClient.probe(socketPath: NSHomeDirectory() + "/Library/Application Support/SpotFast/FSearch/fsearch.sock")
        print("Verified hardened FSearch endpoint")
    } catch { fputs("FSearch check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
