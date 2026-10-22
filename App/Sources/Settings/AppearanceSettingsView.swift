import SwiftUI
import PleviDomain

/// How the app looks as a whole, rather than how any one page does:
/// light or dark, which icon is on the Home screen, and which tabs exist.
struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                @Bindable var settings = app.settings
                SettingRow(title: "Theme") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("App Icon") {
                SettingItem {
                    NavigationLink("Icon") { AppIconSettingsView() }
                }
            }

            Section("Tabs") {
                @Bindable var settings = app.settings
                SettingItem {
                    Toggle("Playlists tab", isOn: $settings.showsPlaylistsTab)
                }

                SettingItem {
                    Toggle("Downloads tab", isOn: $settings.showsDownloadsTab)
                }
            }
            .listRowInsets(EdgeInsets(top: 9, leading: 16, bottom: 5, trailing: 16))
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}
