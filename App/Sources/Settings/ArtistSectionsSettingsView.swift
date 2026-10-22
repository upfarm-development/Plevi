import SwiftUI

/// Reorder the sections of the artist page and choose how each is laid out.
/// Drag to reorder; the menu on each row is that section's layout, with Off
/// among the choices so one control answers both questions.
struct ArtistSectionsSettingsView: View {
    @Environment(AppModel.self) private var app
    /// Only ever written, never read: "Set all" is an action, not a state,
    /// and after it runs the rows themselves are the state.
    @State private var setAll: SectionLayout?

    var body: some View {
        @Bindable var settings = app.settings
        List {
            Section {
                row("Set all", selection: Binding(
                    get: { setAll },
                    set: { newValue in
                        setAll = newValue
                        if let newValue { settings.setAllLayouts(newValue) }
                    }
                ))
                .moveDisabled(true)

                ForEach(settings.artistSectionOrder) { section in
                    if section == .eps, settings.combinesSinglesAndEPs {
                        // Combined, EPs are drawn under the Singles heading with the Singles layout
                        // — this row would set a layout nothing reads and switch off a section that
                        // is not shown separately.
                        EmptyView()
                    } else if section.allowsLayoutChoice {
                        row(
                            section == .singles && settings.combinesSinglesAndEPs
                                ? "Singles & EPs"
                                : section.title,
                            selection: Binding(
                                get: { settings.layout(section) },
                                set: { settings.setLayout($0, for: section) }
                            )
                        )
                    } else {
                        // Nothing to lay out — About is prose, and the two
                        // song shelves are always the same compact list.
                        SettingToggle(section.title, isOn: Binding(
                            get: { settings.isEnabled(section) },
                            set: { settings.setLayout($0 ? .list : .off, for: section) }
                        ))
                    }
                }
                .onMove { indices, destination in
                    settings.artistSectionOrder.move(fromOffsets: indices, toOffset: destination)
                }
            } header: {
                Text("Sections")
            }

            Section {
                SettingItem {
                    SettingToggle("Combine Singles & EPs", isOn: $settings.combinesSinglesAndEPs)
                }
            }

            Section("Album Page") {
                SettingItem(caption: "Navidrome needs its Last.fm agent for reviews.") {
                    SettingToggle("Album review", isOn: $settings.showsAlbumReview)
                }

                SettingItem(caption: "Plex only, once it has analysed the library.") {
                    SettingToggle("Sonically similar albums", isOn: $settings.showsSimilarAlbums)
                }

                if settings.showsAlbumReview {
                    SettingRow(title: "Review position") {
                        Picker("Review position", selection: $settings.albumReviewPosition) {
                            ForEach(SectionPosition.allCases) { position in
                                Text(position.label).tag(position)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Pages")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, selection: Binding<SectionLayout>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            LayoutSelector(selection: selection.wrappedValue) { selection.wrappedValue = $0 }
                .frame(width: Self.selectorWidth)
        }
    }

    /// "Set all" starts with nothing selected, because it is an action rather
    /// than a state: what the sections are set to is on the rows below.
    private func row(_ title: String, selection: Binding<SectionLayout?>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            LayoutSelector(selection: selection.wrappedValue) { selection.wrappedValue = $0 }
                .frame(width: Self.selectorWidth)
        }
        // The rows below reserve room for their drag handle; without the same
        // gap this row's selector would sit further right than all of them.
        .padding(.trailing, Self.reorderHandleWidth)
    }

    private static let selectorWidth: CGFloat = 168
    private static let reorderHandleWidth: CGFloat = 32
}
