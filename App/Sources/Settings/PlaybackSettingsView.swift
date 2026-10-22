import SwiftUI
import PleviAudio

/// The audio pipeline: which engine, the equaliser, crossfade and levelling.
struct PlaybackSettingsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        List {
            Section {
                SettingItem {
                    NavigationLink {
                        ShuffleSettingsView()
                    } label: {
                        LabeledContent(
                            "Shuffle",
                            value: app.settings.smartShuffleByDefault ? "Smart" : "Classic"
                        )
                    }
                }
            }

            Section {
                // One row each. Wrapped in a single `SettingItem` they were
                // stacked in one row, which only worked while each carried a
                // caption of its own to space it out.
                ForEach(QueueOrigin.Kind.allCases) { origin in
                    Toggle(isOn: Binding(
                        get: { app.settings.smartContinue(for: origin) },
                        set: { app.settings.setSmartContinue($0, for: origin) }
                    )) {
                        Text(origin.label)
                    }
                }
            } header: {
                Text("Smart Continue")
            }

            Section {
                @Bindable var settings = app.settings
                SettingItem {
                    Picker("Songs per gap", selection: $settings.djInsertionCount) {
                        ForEach(2...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                }
            } header: {
                Text("DJ")
            }

            Section("Audio") {
                @Bindable var settings = app.settings
                SettingItem {
                    NavigationLink {
                        EqualizerSettingsView()
                    } label: {
                        LabeledContent(
                            "Equaliser",
                            value: settings.equalizerPresetName.isEmpty
                                ? "Custom"
                                : settings.equalizerPresetName
                        )
                    }
                }

                SettingRow(title: "Volume levelling") {
                    Picker("Volume levelling", selection: $settings.replayGainMode) {
                        Text("Off").tag(ReplayGainMode.off)
                        Text("Per track").tag(ReplayGainMode.track)
                        Text("Per album").tag(ReplayGainMode.album)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if settings.replayGainMode.isEnabled {
                    SettingItem {
                        Stepper(value: $settings.replayGainPreampDB, in: -12...12, step: 1) {
                            HStack {
                                Text("Preamp")
                                Spacer(minLength: 8)
                                Text(Self.preampLabel(settings.replayGainPreampDB))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }

                SettingItem {
                    Toggle("Limiter", isOn: $settings.limiterEnabled)
                }

            }

            smartFades

        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        // Applied to the running engine as they change, so the effect is audible while the setting
        // is still on screen.
        .onChange(of: app.settings.equalizerGainsDB) { app.player.applyAudioSettings(app.settings) }
        .onChange(of: app.settings.replayGainMode) { app.player.applyAudioSettings(app.settings) }
        .onChange(of: app.settings.replayGainPreampDB) { app.player.applyAudioSettings(app.settings) }
    }

    private static func preampLabel(_ db: Double) -> String {
        db == 0 ? "0 dB" : String(format: "%+.0f dB", db)
    }

    /// The transition section.
    @ViewBuilder
    private var smartFades: some View {
        @Bindable var settings = app.settings
        Section("Transitions") {
            SettingItem {
                Toggle("Smart fades", isOn: $settings.smartFades)
            }

            if settings.smartFades {
                SettingRow(title: "Longest overlap") {
                    Text("\(Int(settings.maxOverlapSeconds))s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.maxOverlapSeconds, in: 1...12, step: 1)
                    .padding(.horizontal)

                SettingItem {
                    Toggle("Fade across the overlap", isOn: Binding(
                        get: { settings.fadeEnvelope == .smooth },
                        set: { settings.fadeEnvelope = $0 ? .smooth : .overlapOnly }
                    ))
                }

                SettingItem {
                    Toggle("Keep albums gapless", isOn: $settings.keepAlbumsGapless)
                }

                SettingItem {
                    Toggle("Match sample rates", isOn: $settings.matchSampleRates)
                }
            }
        }
    }
}
