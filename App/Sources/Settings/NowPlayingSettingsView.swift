import SwiftUI
import PleviDomain

/// The playing screen: what it shows, and what it asks before it stops.
struct NowPlayingSettingsView: View {
    @Environment(AppModel.self) private var app

    /// iPad's own screen has no Bleed to choose — it is always framed, the one arrangement its
    /// side-by-side layout was drawn for — so the choice itself is dropped here rather than left
    /// pointing at a screen that no longer answers to it.
    private var isIPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        List {
            if !isIPad {
                Section("Layout") {
                    @Bindable var settings = app.settings
                    SettingRow(title: "Layout") {
                        Picker("Layout", selection: $settings.nowPlayingLayout) {
                            ForEach(NowPlayingLayout.allCases) { layout in
                                Text(layout.label).tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }

            if isIPad {
                Section("Queue") {
                    @Bindable var settings = app.settings
                    SettingItem {
                        Toggle("Open in landscape", isOn: $settings.queueRailExpandedLandscape)
                    }
                    Toggle("Open in portrait", isOn: $settings.queueRailExpandedPortrait)
                }
            }

            Section("Screen") {
                @Bindable var settings = app.settings
                SettingItem {
                    Toggle("Lyrics", isOn: $settings.showsLyrics)
                }

                SettingItem {
                    Toggle("Confirm stop and clear", isOn: $settings.confirmsStopAndClear)
                }

                SettingRow(title: "Progress bar") {
                    Picker("Progress bar", selection: $settings.progressStyle) {
                        ForEach(ProgressStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Only the full-bleed layout draws the bar white, and iPad
                // has no full-bleed layout, so there it would switch nothing.
                if !isIPad {
                    SettingItem {
                        Toggle("Colour it like the stars", isOn: $settings.tintsProgressLikeStars)
                    }
                }
            }

            Section("Scrolling Text") {
                @Bindable var settings = app.settings
                SettingItem {
                    Toggle("Song title", isOn: $settings.rollsTitle)
                }
                Toggle("Artist", isOn: $settings.rollsArtist)
                Toggle("Album", isOn: $settings.rollsAlbum)
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
    }
}
