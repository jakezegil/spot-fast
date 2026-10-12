import AppKit
import Combine
import Contacts
import SpotFastCore

@MainActor final class ContactStore: ObservableObject {
    @Published private(set) var status = "Allow Contacts to search people and open Messages."
    @Published private(set) var loading = false
    @Published private(set) var canRequest = false
    private(set) var index = ContactIndex(entries: [])
    var changed: (() -> Void)?
    private let systemAccess: Bool
    private var enabled = true
    private var busy = false
    private var queued = false
    private var revision = 0
    private var observer: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private let worker = DispatchQueue(label: "SpotFast.contacts", qos: .utility)
    init(systemAccess: Bool = true) {
        self.systemAccess = systemAccess
        guard systemAccess else { return }
        observer = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermission() }
        }
    }
    func configure(enabled: Bool) {
        guard systemAccess else { return }
        let wasEnabled = self.enabled; self.enabled = enabled
        if !enabled {
            revision += 1; index = ContactIndex(entries: []); status = "Contact search is off."; canRequest = false; loading = false; changed?()
        } else if !wasEnabled || index.entries.isEmpty { refresh() }
        else { checkPermission() }
    }
    private func checkPermission() {
        guard enabled, systemAccess else { return }
        if CNContactStore.authorizationStatus(for: .contacts) != .authorized || index.entries.isEmpty { refresh() }
    }
    func requestAccess() {
        guard enabled, systemAccess, canRequest else { return }
        canRequest = false
        // Permission is requested only by an explicit Allow Contacts button.
        CNContactStore().requestAccess(for: .contacts) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func refresh() {
        guard enabled, systemAccess else { return }
        let authorization = CNContactStore.authorizationStatus(for: .contacts)
        guard authorization == .authorized else {
            revision += 1; index = ContactIndex(entries: []); loading = false
            canRequest = authorization == .notDetermined
            status = canRequest ? "Allow Contacts to search people and open Messages." : "Enable SpotFast in System Settings → Privacy & Security → Contacts."
            changed?(); return
        }
        guard !busy else { queued = true; return }
        busy = true; loading = true; canRequest = false
        let token = revision
        worker.async { [weak self] in
            let result = Result { () -> ContactIndex in
                let store = CNContactStore()
                let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor, CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
                let request = CNContactFetchRequest(keysToFetch: keys); request.unifyResults = true
                var entries: [ContactEntry] = []
                try store.enumerateContacts(with: request) { contact, _ in
                    let phones = contact.phoneNumbers.sorted { a, b in
                        func priority(_ label: String?) -> Int { label == CNLabelPhoneNumberMobile || label == CNLabelPhoneNumberiPhone ? 0 : 1 }
                        return priority(a.label) < priority(b.label)
                    }.map { ContactAddress(label: $0.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "Phone", value: $0.value.stringValue) }
                    let emails = contact.emailAddresses.map { ContactAddress(label: $0.label.map(CNLabeledValue<NSString>.localizedString(forLabel:)) ?? "Email", value: $0.value as String, isEmail: true) }
                    let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
                    entries.append(ContactEntry(id: contact.identifier, name: name.isEmpty ? "Unnamed contact" : name, addresses: phones + emails))
                }
                return ContactIndex(entries: entries)
            }
            Task { @MainActor in
                guard let self else { return }
                self.busy = false; self.loading = false
                if self.enabled, token == self.revision, CNContactStore.authorizationStatus(for: .contacts) == .authorized {
                    switch result {
                    case .success(let index): self.index = index; self.status = "\(index.entries.count) contacts · opens Messages"
                    case .failure: self.index = ContactIndex(entries: []); self.status = "Couldn't load contacts. Try refreshing."
                    }
                    self.changed?()
                }
                if self.queued { self.queued = false; self.refresh() }
            }
        }
    }
    func setTestEntries(_ entries: [ContactEntry]) {
        guard !systemAccess else { return }
        index = ContactIndex(entries: entries); status = "Test contacts"; changed?()
    }
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") { NSWorkspace.shared.open(url) }
    }
}
