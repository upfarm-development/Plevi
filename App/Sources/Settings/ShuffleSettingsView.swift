import SwiftUI
import PleviDomain

/// What the smart shuffle pays attention to.
struct ShuffleSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        List {
            Section {
                SettingToggle("Smart shuffle by default", isOn: $settings.smartShuffleByDefault)
            } footer: {
                Text(settings.smartShuffleByDefault
                     ? "The shuffle button does the smart shuffle. Hold it for the classic one."
                     : "The shuffle button does the classic shuffle. Hold it for the smart one.")
            }

            Section {
                ForEach(settings.smartShuffle.completeRanking) { signal in
                    row(for: signal, settings: settings)
                }
                .onMove { indices, destination in
                    var ranking = settings.smartShuffle.completeRanking
                    ranking.move(fromOffsets: indices, toOffset: destination)
                    settings.smartShuffle.ranking = ranking
                }
            } header: {
                Text("What it weighs")
            } footer: {
                Text("The order is the weighting.")
            }

            Section {
                spacingRow(
                    title: "Same artist",
                    value: $settings.smartShuffle.artistSpacing
                )
                spacingRow(
                    title: "Same album",
                    value: $settings.smartShuffle.albumSpacing
                )
            } header: {
                Text("Keep apart")
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Shuffle")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(for signal: ShuffleSignal, settings: AppSettings) -> some View {
        SettingToggle(signal.label, isOn: Binding(
            get: { settings.smartShuffle.enabled.contains(signal) },
            set: { isOn in
                if isOn {
                    settings.smartShuffle.enabled.insert(signal)
                } else {
                    settings.smartShuffle.enabled.remove(signal)
                }
            }
        ))
    }

    private func spacingRow(title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...12) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text(value.wrappedValue == 0 ? "None" : "\(value.wrappedValue) songs")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}
