import SwiftUI
import PleviLibraryIndex

/// Which shelves Home shows, in what order, and any built from your own filters.
struct HomeSectionsSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var editing: CustomHomeSection?
    @State private var creating = false
    @State private var arrangingPins = false

    var body: some View {
        @Bindable var settings = app.settings
        List {
            Section {
                ForEach(settings.homeSectionOrder) { section in
                    row(for: section, settings: settings)
                        // Built-in shelves are switched off, not deleted, so
                        // they do not offer a delete that would do nothing.
                        .deleteDisabled(!section.isCustom)
                }
                .onMove { indices, destination in
                    settings.homeSectionOrder.move(fromOffsets: indices, toOffset: destination)
                }
                .onDelete { offsets in
                    remove(offsets, from: settings)
                }
            } header: {
                Text("Shelves")
            }

            Section {
                // A button rather than a NavigationLink: this list keeps edit
                // mode switched on, and a link inside an editing list does not
                // answer to a tap.
                Button {
                    arrangingPins = true
                } label: {
                    HStack(spacing: 10) {
                        Label("Pinned Items", systemImage: "pin")
                        Spacer(minLength: 4)
                        Text(app.pins.items.count, format: .number)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section {
                Button {
                    creating = true
                } label: {
                    Label("New Shelf", systemImage: "plus")
                        // The whole row, not just the words and the plus.
                        // A row that only answers to a tap on its icon is a
                        // row that feels broken.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $creating) {
            FilterEditorView(section: CustomHomeSection(), isNew: true)
        }
        .navigationDestination(item: $editing) { section in
            FilterEditorView(section: section, isNew: false)
        }
        .navigationDestination(isPresented: $arrangingPins) {
            PinnedItemsSettingsView()
        }
    }

    @ViewBuilder
    private func row(for section: HomeSection, settings: AppSettings) -> some View {
        if let id = section.customID {
            if let custom = app.customSections.section(id: id) {
                HStack(spacing: 10) {
                    Text(custom.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Button {
                        editing = custom
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 30)
                            .contentShape(Rectangle())
                    }
                    // A button inside another button's label never receives
                    // its taps; this sits beside the selector rather than
                    // within it.
                    .buttonStyle(.plain)
                    // Songs get the choice too now: a shelf of them can be a list of five with the
                    // rest behind More, or the card that plays the lot.
                    control(for: section, settings: settings, hasLayouts: true)
                }
            }
        } else {
            HStack(spacing: 10) {
                Text(section.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                control(
                    for: section,
                    settings: settings,
                    hasLayouts: section.supportsLayoutChoice
                )
            }
        }
    }

    /// The four-way selector where the shelf has a shape to choose, and a plain switch where it
    /// does not.
    @ViewBuilder
    private func control(
        for section: HomeSection,
        settings: AppSettings,
        hasLayouts: Bool
    ) -> some View {
        if hasLayouts {
            LayoutSelector(selection: settings.homeSelectorLayout(section)) {
                settings.setHomeSelectorLayout($0, for: section)
            }
            .frame(width: Self.selectorWidth)
        } else {
            Toggle("", isOn: Binding(
                get: { settings.isEnabled(section) },
                set: { settings.setEnabled($0, for: section) }
            ))
            .labelsHidden()
        }
    }

    /// The same width the Pages screen gives its own selector, so the two
    /// screens line up rather than merely resembling each other.
    private static let selectorWidth: CGFloat = 168

    /// Only shelves someone made can be deleted; the built-in ones are
    /// switched off instead, which is what the switch is for.
    private func remove(_ offsets: IndexSet, from settings: AppSettings) {
        let doomed = offsets
            .filter { settings.homeSectionOrder.indices.contains($0) }
            .map { settings.homeSectionOrder[$0] }
            .filter(\.isCustom)
        guard !doomed.isEmpty else { return }
        for section in doomed {
            if let id = section.customID {
                app.customSections.delete(id: id)
            }
        }
        settings.homeSectionOrder.removeAll { doomed.contains($0) }
    }
}
