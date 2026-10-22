import SwiftUI
import PleviAudio

/// The equaliser: the bands themselves at the top, the presets underneath.
struct EqualizerSettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var isNaming = false
    @State private var newName = ""

    private var settings: AppSettings { app.settings }

    var body: some View {
        List {
            // §4.8.1: "While this phone controls another device, Settings › Equalizer still adjusts
            // only this phone, and its footer says so." EQ is deliberately never remote (§4.10) —
            // this is the reminder, not a gate: the bands below still work exactly…
            if let name = app.remote.controlledDeviceName {
                Section {
                    Text("This equaliser is for what plays on this device — it has no effect on \(name).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                bands
                    .listRowInsets(EdgeInsets(top: 18, leading: 12, bottom: 10, trailing: 12))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Bands")
            }

            Section {
                Button("Save as a preset…") {
                    // Empty, with the placeholder doing the explaining.
                    newName = ""
                    isNaming = true
                }
                .disabled(settings.equalizerGainsDB.allSatisfy { $0 == 0 })
                Button("Reset to flat") {
                    apply(.flat)
                }
                .disabled(settings.equalizerGainsDB.allSatisfy { $0 == 0 })
            }

            Section("Presets") {
                ForEach(EqualizerPreset.builtIn) { preset in
                    row(preset)
                }
            }

            if !settings.customEqualizerPresets.isEmpty {
                Section {
                    ForEach(settings.customEqualizerPresets) { preset in
                        row(preset)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            let preset = settings.customEqualizerPresets[index]
                            app.settings.removeCustomEqualizerPreset(preset)
                        }
                        app.player.applyAudioSettings(app.settings)
                    }
                } header: {
                    Text("Your Presets")
                }
            }
        }
        .navigationTitle("Equaliser")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Save preset", isPresented: $isNaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                app.settings.saveCurrentEqualizerCurve(named: newName)
            }
        } message: {
            Text("Saves the current band settings.")
        }
    }

    /// Ten vertical faders, one per band, labelled with their frequency.
    private var bands: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(Equalizer.bandFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 6) {
                    Text(gainLabel(for: index))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    BandSlider(
                        gainDB: Binding(
                            get: { settings.equalizerGainsDB.indices.contains(index)
                                ? settings.equalizerGainsDB[index] : 0 },
                            set: { newValue in
                                app.settings.setEqualizerBand(index, toGainDB: newValue)
                                app.player.applyAudioSettings(app.settings)
                            }
                        )
                    )
                    .frame(height: 150)
                    Text(Equalizer.label(forFrequency: frequency))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func gainLabel(for index: Int) -> String {
        let gain = settings.equalizerGainsDB.indices.contains(index)
            ? settings.equalizerGainsDB[index]
            : 0
        return gain == 0 ? "0" : String(format: "%+.0f", gain)
    }

    private func row(_ preset: EqualizerPreset) -> some View {
        Button {
            apply(preset)
        } label: {
            HStack {
                Text(preset.name)
                    .foregroundStyle(.primary)
                Spacer()
                if preset.name == settings.equalizerPresetName {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("In use")
                }
            }
        }
    }

    private func apply(_ preset: EqualizerPreset) {
        app.settings.applyEqualizerPreset(preset)
        app.player.applyAudioSettings(app.settings)
    }

}

/// One band's fader.
private struct BandSlider: View {
    @Binding var gainDB: Double

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let range = Equalizer.maximumGainDB - Equalizer.minimumGainDB
            let middle = height / 2
            let offset = CGFloat(gainDB / range) * height

            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 5)
                // From the centre towards the current value, so a cut reads as
                // clearly as a boost rather than both looking like "some fill".
                Capsule()
                    .fill(.tint)
                    .frame(width: 5, height: abs(offset))
                    .offset(y: offset > 0 ? -middle : -middle + abs(offset))
                Circle()
                    .fill(.background)
                    .overlay(Circle().strokeBorder(.tint, lineWidth: 2))
                    .frame(width: 18, height: 18)
                    .offset(y: -middle - offset + 9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fromCentre = middle - value.location.y
                        gainDB = Equalizer.clamp(Double(fromCentre / height) * range)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Band gain")
        .accessibilityValue("\(Int(gainDB)) decibels")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: gainDB = Equalizer.clamp(gainDB + 1)
            case .decrement: gainDB = Equalizer.clamp(gainDB - 1)
            @unknown default: break
            }
        }
    }
}
