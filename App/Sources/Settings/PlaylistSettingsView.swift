import SwiftUI
import PleviDomain

/// Playlist pages, and the order the list of them comes in.
struct PlaylistSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            Section {
                @Bindable var settings = app.settings
                SettingRow(title: "Playlist background") {
                    Picker("Playlist background", selection: $settings.playlistPageStyle) {
                        ForEach(PageStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("List") {
                @Bindable var settings = app.settings
                SettingRow(title: "Order") {
                    Picker("Order", selection: $settings.playlistSorting) {
                        ForEach(PlaylistSorting.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationBarTitleDisplayMode(.inline)
    }
}
