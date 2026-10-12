import Foundation

public struct SystemSettingsPane: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let aliases: [String]
    public let bundleIdentifier: String
    public let legacyIdentifier: String?
    public let anchor: String?
    public init(_ title: String, _ bundleIdentifier: String, symbol: String, aliases: [String] = [], legacy: String? = nil, anchor: String? = nil) {
        self.title = title; self.bundleIdentifier = bundleIdentifier; self.symbol = symbol
        self.aliases = aliases; self.legacyIdentifier = legacy; self.anchor = anchor
        id = bundleIdentifier + (anchor.map { "?" + $0 } ?? "")
    }
    public func destination(installed: Set<String>? = nil) -> URL? {
        let identifier: String
        if installed == nil || installed!.contains(bundleIdentifier) { identifier = bundleIdentifier }
        else if let legacyIdentifier, installed!.contains(legacyIdentifier) { identifier = legacyIdentifier }
        else { return nil }
        // Identifiers and anchors come only from the static catalog, never the query.
        return URL(string: "x-apple.systempreferences:" + identifier + (anchor.map { "?" + $0 } ?? ""))
    }
}

public enum SystemSettingsCatalog {
    public struct Hit: Sendable {
        public let pane: SystemSettingsPane
        public let destination: URL
        public let score: Double
    }
    public static let panes: [SystemSettingsPane] = [
        .init("Sound", "com.apple.Sound-Settings.extension", symbol: "speaker.wave.2", aliases: ["volume", "audio", "speakers", "sound output", "sound input", "microphone settings"]),
        .init("Displays", "com.apple.Displays-Settings.extension", symbol: "display", aliases: ["display", "monitor", "screen resolution", "brightness", "night shift"]),
        .init("Keyboard", "com.apple.Keyboard-Settings.extension", symbol: "keyboard", aliases: ["keyboard shortcuts", "typing", "text replacements"]),
        .init("Trackpad", "com.apple.Trackpad-Settings.extension", symbol: "rectangle.and.hand.point.up.left", aliases: ["gestures"]),
        .init("Mouse", "com.apple.Mouse-Settings.extension", symbol: "computermouse", aliases: ["mouse speed"]),
        .init("Bluetooth", "com.apple.BluetoothSettings", symbol: "antenna.radiowaves.left.and.right", aliases: ["bluetooth devices"]),
        .init("Wi-Fi", "com.apple.wifi-settings-extension", symbol: "wifi", aliases: ["wifi", "wi fi", "wireless"]),
        .init("Network", "com.apple.Network-Settings.extension", symbol: "network", aliases: ["ethernet", "network connections"], legacy: "com.apple.preference.network"),
        .init("Notifications", "com.apple.Notifications-Settings.extension", symbol: "bell", aliases: ["notification", "alerts"]),
        .init("Focus", "com.apple.Focus-Settings.extension", symbol: "moon", aliases: ["do not disturb", "dnd"]),
        .init("Appearance", "com.apple.Appearance-Settings.extension", symbol: "circle.lefthalf.filled", aliases: ["dark mode", "light mode", "accent color"], legacy: "com.apple.preference.general"),
        .init("Accessibility", "com.apple.Accessibility-Settings.extension", symbol: "accessibility", aliases: ["voiceover", "zoom accessibility"], legacy: "com.apple.preference.universalaccess"),
        .init("Privacy & Security", "com.apple.settings.PrivacySecurity.extension", symbol: "hand.raised", aliases: ["privacy", "security", "permissions"], legacy: "com.apple.preference.security"),
        .init("Wallpaper", "com.apple.Wallpaper-Settings.extension", symbol: "photo", aliases: ["background", "desktop background"]),
        .init("Desktop & Dock", "com.apple.Desktop-Settings.extension", symbol: "dock.rectangle", aliases: ["dock", "desktop", "mission control", "stage manager"], legacy: "com.apple.preference.dock"),
        .init("Screen Saver", "com.apple.ScreenSaver-Settings.extension", symbol: "sparkles.tv", aliases: ["screensaver"]),
        .init("Lock Screen", "com.apple.Lock-Screen-Settings.extension", symbol: "lock", aliases: ["screen lock", "screen timeout"]),
        .init("Login Items", "com.apple.LoginItems-Settings.extension", symbol: "person.crop.circle.badge.checkmark", aliases: ["startup apps", "login apps", "background items"]),
        .init("Software Update", "com.apple.Software-Update-Settings.extension", symbol: "arrow.triangle.2.circlepath", aliases: ["updates", "update macos", "macos update"]),
        .init("Storage", "com.apple.settings.Storage", symbol: "internaldrive", aliases: ["disk space", "storage space"]),
        .init("Battery", "com.apple.Battery-Settings.extension", symbol: "battery.100percent", aliases: ["power", "low power mode"]),
        .init("Sharing", "com.apple.Sharing-Settings.extension", symbol: "square.and.arrow.up", aliases: ["file sharing", "screen sharing", "remote login"]),
        .init("Printers & Scanners", "com.apple.Print-Scan-Settings.extension", symbol: "printer", aliases: ["printer", "scanner", "printing"]),
        .init("Date & Time", "com.apple.Date-Time-Settings.extension", symbol: "clock", aliases: ["date", "time zone", "clock settings"], legacy: "com.apple.preference.datetime"),
        .init("Language & Region", "com.apple.Localization-Settings.extension", symbol: "globe", aliases: ["language", "region", "locale"]),
        .init("Users & Groups", "com.apple.Users-Groups-Settings.extension", symbol: "person.2", aliases: ["users", "accounts", "user accounts"], legacy: "com.apple.preferences.users"),
        .init("Time Machine", "com.apple.Time-Machine-Settings.extension", symbol: "clock.arrow.circlepath", aliases: ["backup", "backups"]),
        .init("Screen Time", "com.apple.Screen-Time-Settings.extension", symbol: "hourglass", aliases: ["parental controls", "app limits"]),
        .init("General", "com.apple.systempreferences.GeneralSettings", symbol: "gearshape", aliases: ["general settings"]),
        .init("Microphone Permissions", "com.apple.settings.PrivacySecurity.extension", symbol: "mic", aliases: ["microphone", "microphone privacy"], anchor: "Privacy_Microphone"),
        .init("Camera Permissions", "com.apple.settings.PrivacySecurity.extension", symbol: "camera", aliases: ["camera", "camera privacy"], anchor: "Privacy_Camera"),
        .init("Screen Recording Permissions", "com.apple.settings.PrivacySecurity.extension", symbol: "record.circle", aliases: ["screen recording", "screen capture permissions"], anchor: "Privacy_ScreenCapture")
    ]
    public static func search(_ query: String, installed: Set<String>? = nil) -> [Hit] {
        var input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return [] }
        var explicit = false
        for prefix in ["system settings ", "system preferences ", "settings ", "preferences ", "settings:"] {
            if input.lowercased().hasPrefix(prefix) { input = String(input.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces); explicit = true; break }
        }
        for suffix in [" settings", " preferences"] {
            if input.lowercased().hasSuffix(suffix) { input = String(input.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces); explicit = true; break }
        }
        let browse = ["settings", "preferences", "system settings", "system preferences"].contains(input.lowercased())
        guard browse || (!input.isEmpty && !ResultRanking.hasFileIntent(input)) else { return [] }
        return panes.compactMap { pane in
            guard let destination = pane.destination(installed: installed) else { return nil }
            if browse { return Hit(pane: pane, destination: destination, score: 750) }
            let scores = ([pane.title] + pane.aliases).compactMap { name -> Double? in
                guard let match = ResultRanking.match(name, query: input) else { return nil }
                switch match {
                case .exact: return 1700
                case .word: return input.count >= 3 ? 1500 : nil
                case .prefix, .wordPrefix: return input.count >= 3 ? 1450 : nil
                case .initials, .substring, .fuzzy: return nil
                }
            }
            guard let score = scores.max() else { return nil }
            return Hit(pane: pane, destination: destination, score: score + (explicit ? 50 : 0))
        }.sorted { $0.score == $1.score ? $0.pane.id < $1.pane.id : $0.score > $1.score }
    }
    /// Read Apple-installed bundle metadata once, away from the keystroke path.
    public static func installedIdentifiers() -> Set<String> {
        let roots = ["/System/Library/ExtensionKit/Extensions", "/System/Library/PreferencePanes", "/System/Applications/System Settings.app/Contents/PlugIns"]
        var identifiers = Set<String>()
        for root in roots {
            let bundles = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil)) ?? []
            for url in bundles where ["appex", "prefPane"].contains(url.pathExtension) {
                if let id = Bundle(url: url)?.bundleIdentifier { identifiers.insert(id) }
            }
        }
        return identifiers
    }
}
