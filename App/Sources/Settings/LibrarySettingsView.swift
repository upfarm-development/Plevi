import SwiftUI
import PleviDomain

/// Album and artist pages, and the rows of songs on them.
struct LibrarySettingsView: View {
    @Environment(AppModel.self) private var app

    private var allowsHalfStars: Bool {
        app.provider?.capabilities.contains(.halfStarRatings) ?? false
    }

    /// A style the server cannot store shows as the whole-star one it falls
    /// back to, while the stored choice is left alone underneath.
    private var ratingStyle: Binding<RatingStyle> {
        Binding(
            get: { app.settings.ratingStyle.resolved(halfStars: allowsHalfStars) },
            set: { app.settings.ratingStyle = $0 }
        )
    }

    var body: some View {
        List {
            Section("Pages") {
                @Bindable var settings = app.settings
                SettingRow(title: "Artwork background") {
                    Picker("Artwork background", selection: $settings.pageStyle) {
                        ForEach(PageStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if UIDevice.current.userInterfaceIdiom == .pad {
                    // Counts depend on how the iPad is held, so the choice is
                    // how much to fit rather than how many: three across in
                    // portrait and four in landscape, or one more of each.
                    SettingRow(title: "Grid density") {
                        Picker("Grid density", selection: $settings.highGridDensity) {
                            Text("Low").tag(false)
                            Text("High").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                } else {
                    SettingRow(title: "Albums per row") {
                        Picker("Albums per row", selection: $settings.albumsPerRow) {
                            Text("2").tag(2)
                            Text("3").tag(3)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                SettingItem {
                    NavigationLink {
                        ArtistSectionsSettingsView()
                    } label: {
                        Text("Page sections")
                    }
                }
            }

            Section("Track Rows") {
                @Bindable var settings = app.settings
                SettingRow(title: "Row style") {
                    Picker("Row style", selection: $settings.trackRowStyle) {
                        ForEach(TrackRowStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("Codec Badge") {
                @Bindable var settings = app.settings
                SettingItem {
                    Toggle("On album pages", isOn: $settings.showsCodecBadge)
                }

                SettingItem {
                    Toggle("On Now Playing", isOn: $settings.showsCodecInfo)
                }

                if settings.showsCodecBadge || settings.showsCodecInfo {
                    SettingItem {
                        Toggle("Bit rate for lossy formats", isOn: $settings.badgeShowsLossyBitRate)
                    }

                    SettingItem {
                        Toggle("kHz and bit depth for lossless", isOn: $settings.badgeShowsLosslessDetail)
                    }
                }
            }

            Section("Ratings") {
                @Bindable var settings = app.settings
                SettingItem {
                    Picker("Show ratings", selection: $settings.ratingVisibility) {
                        ForEach(RatingVisibility.allCases) { visibility in
                            Text(visibility.label).tag(visibility)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                SettingItem {
                    Toggle("Only on rated songs", isOn: $settings.showsStarsOnlyWhenRated)
                }

                SettingItem {
                    Toggle("In the queue", isOn: $settings.showsRatingsInQueue)
                        .disabled(settings.ratingVisibility == .hidden)
                }

                SettingItem {
                    Picker("Rating style", selection: ratingStyle) {
                        ForEach(RatingStyle.available(halfStars: allowsHalfStars)) { style in
                            Text(style.label).tag(style)
                        }
                    }
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.inline)
    }
}
