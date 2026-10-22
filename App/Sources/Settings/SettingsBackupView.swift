import SwiftUI

/// What iCloud is keeping, and the one button that puts it back.
struct SettingsBackupView: View {
    @Environment(AppModel.self) private var app

    @State private var restored: Int?
    @State private var confirming = false

    private var store: SettingsBackupStore { app.settingsBackup }

    var body: some View {
        List {
            Section {
                if let stored = store.stored {
                    LabeledContent("Last kept", value: stored.writtenAt.formatted(.relative(presentation: .named)))
                    LabeledContent("From", value: stored.deviceName)
                    LabeledContent("Settings", value: "\(stored.count)")
                } else {
                    Text(store.isAvailable ? "Nothing kept yet." : "iCloud is not available on this device.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("In iCloud")
            } footer: {
                Text(footer)
            }

            if store.stored != nil {
                Section {
                    Button("Restore These Settings") { confirming = true }
                        // On the button that asked it.
                        .confirmationDialog(
                            "Replace this device's settings?",
                            isPresented: $confirming,
                            titleVisibility: .visible
                        ) {
                            Button("Restore", role: .destructive) {
                                restored = store.restoreNow()
                                // The Home arrangement is read again now; the rest of the
                                // settings are read when the app starts.
                                app.homeRestoredFromBackup()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The settings kept from \(store.stored?.deviceName ?? "another device") will be used instead of this device's own.")
                        }
                }
            }
        }
        .navigationTitle("Settings Backup")
        .alert(
            "Restored",
            isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })
        ) {
            Button("OK") { restored = nil }
        } message: {
            // A count rather than a tick: a restore that brought nothing back
            // and one that brought everything look identical otherwise, which
            // is how a half-working backup goes unnoticed for months.
            Text(restoredMessage)
        }
    }

    private var restoredMessage: String {
        switch restored {
        case .some(0): "Nothing was restored."
        case .some(1): "1 setting restored. Some take effect next time the app starts."
        case .some(let count): "\(count) settings restored. Some take effect next time the app starts."
        case nil: ""
        }
    }

    /// Said plainly, because the honest version of this feature is narrower
    /// than "your settings are safe" and somebody relying on it should know
    /// which half they are relying on.
    private var footer: String {
        "Servers and passwords are not included."
    }
}
