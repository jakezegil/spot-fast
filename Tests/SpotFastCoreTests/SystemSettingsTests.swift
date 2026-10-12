import XCTest
@testable import SpotFastCore

final class SystemSettingsTests: XCTestCase {
    func testSoundAndVolumeOpenTheSoundPane() {
        for query in ["sound", "volume", "audio", "Sound", "sound settings", "settings sound", "settings:sound"] {
            let hit = SystemSettingsCatalog.search(query).first
            XCTAssertEqual(hit?.pane.title, "Sound", query)
            XCTAssertEqual(hit?.destination.absoluteString, "x-apple.systempreferences:com.apple.Sound-Settings.extension", query)
            XCTAssertGreaterThan(hit?.score ?? 0, ResultRanking.applicationScore("Sound Studio", query: "sound")!)
        }
    }
    func testCommonPaneAliasesAndMultiwordQueries() {
        let expected = ["wifi": "Wi-Fi", "display": "Displays", "keyboard shortcuts": "Keyboard", "dark mode": "Appearance", "disk space": "Storage", "startup apps": "Login Items"]
        for (query, title) in expected { XCTAssertEqual(SystemSettingsCatalog.search(query).first?.pane.title, title, query) }
    }
    func testSettingsSearchDoesNotCompeteWithExplicitFilesOrUnrelatedApps() {
        for query in ["chrome", "vsc", "Sound.swift", "README.md", "~/Downloads/sound", "2+3", "s", "https://example.com"] {
            XCTAssertTrue(SystemSettingsCatalog.search(query).isEmpty, query)
        }
    }
    func testInstalledPaneFilteringAndLegacyFallback() {
        let sound = "com.apple.Sound-Settings.extension"
        XCTAssertEqual(SystemSettingsCatalog.search("sound", installed: [sound]).count, 1)
        XCTAssertTrue(SystemSettingsCatalog.search("sound", installed: []).isEmpty)
        let legacy = SystemSettingsCatalog.search("privacy", installed: ["com.apple.preference.security"]).first
        XCTAssertEqual(legacy?.destination.absoluteString, "x-apple.systempreferences:com.apple.preference.security")
        let modern = SystemSettingsCatalog.search("privacy", installed: ["com.apple.preference.security", "com.apple.settings.PrivacySecurity.extension"]).first
        XCTAssertEqual(modern?.destination.absoluteString, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension")
    }
    func testPrivacySubpagesUseFixedAnchorsAndDistinctIdentities() {
        XCTAssertEqual(SystemSettingsCatalog.search("microphone").first?.destination.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
        XCTAssertEqual(SystemSettingsCatalog.search("camera").first?.destination.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera")
        XCTAssertEqual(SystemSettingsCatalog.search("screen recording").first?.destination.absoluteString,
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        XCTAssertEqual(Set(SystemSettingsCatalog.panes.map(\.id)).count, SystemSettingsCatalog.panes.count)
    }
    func testEmptyInputAndSettingsBrowsingRemainSafe() {
        XCTAssertTrue(SystemSettingsCatalog.search("").isEmpty)
        XCTAssertTrue(SystemSettingsCatalog.search("  ").isEmpty)
        XCTAssertEqual(SystemSettingsCatalog.search("settings").count, SystemSettingsCatalog.panes.count)
        XCTAssertLessThan(SystemSettingsCatalog.search("settings").first!.score,
            ResultRanking.applicationScore("System Settings", query: "settings")!)
    }
    func testQueryCannotInjectADestinationOrAnchor() {
        for query in ["settings:com.apple.Sound-Settings.extension?evil", "sound?Privacy_Camera", "settings https://example.com"] {
            XCTAssertTrue(SystemSettingsCatalog.search(query).isEmpty, query)
        }
        XCTAssertTrue(SystemSettingsCatalog.search("sound output").allSatisfy {
            $0.destination.absoluteString == "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        })
    }
}
