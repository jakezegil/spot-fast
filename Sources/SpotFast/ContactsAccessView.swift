import SwiftUI

struct ContactsAccessView: View {
    @ObservedObject var store: ContactStore
    let enabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if store.loading { ProgressView().controlSize(.small) }
                Text(enabled ? store.status : "Contact search is off.").font(.caption).foregroundStyle(.secondary)
            }
            if enabled {
                if store.canRequest {
                    Button("Allow Contacts…") { store.requestAccess() }
                } else {
                    HStack {
                        Button("Refresh contacts") { store.refresh() }.disabled(store.loading)
                        if store.index.entries.isEmpty {
                            Button("Privacy settings…") { store.openPrivacySettings() }
                        }
                    }
                }
            }
        }
    }
}
