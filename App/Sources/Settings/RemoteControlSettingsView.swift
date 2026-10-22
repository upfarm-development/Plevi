import SwiftUI

/// "The first advertisement starts from the Allow Remote Control toggle."
/// This is that toggle — the minimal real entry point Phase 3's testing needs.
struct RemoteControlSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        List {
            Section {
                // `RemoteControl.setAllowControl` writes the setting and starts or
                // stops listening in the order the flips were made.
                Toggle("Allow Remote Control", isOn: Binding(
                    get: { settings.remoteAllowControl },
                    set: { app.remote.setAllowControl($0) }
                ))
            } footer: {
                Text("Turning this off stops other devices from finding this one.")
            }

            if settings.remoteAllowControl {
                Section {
                    LabeledContent("Status", value: app.remote.isListening ? "Listening for nearby devices" : "Starting…")
                    if let lastError = app.remote.lastError {
                        Text(lastError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Remote Control")
        .navigationBarTitleDisplayMode(.inline)
    }
}
