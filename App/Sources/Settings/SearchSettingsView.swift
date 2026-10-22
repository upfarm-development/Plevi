import SwiftUI

/// The order Search stacks its four kinds of result in.
struct SearchSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        List {
            Section {
                ForEach(settings.searchResultOrder) { kind in
                    Text(kind.title)
                }
                .onMove { indices, destination in
                    settings.searchResultOrder.move(fromOffsets: indices, toOffset: destination)
                }
            }

            Section {
                SettingToggle("Search all quick libraries", isOn: $settings.searchesAllQuickLibraries)
            } footer: {
                if app.quickSwitchChoices.count < 2 {
                    Text("Needs two or more libraries ticked under Quick Switch.")
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Search")
        .navigationBarTitleDisplayMode(.inline)
    }
}
