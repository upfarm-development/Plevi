import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Building a shelf out of rules.
struct FilterEditorView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var section: CustomHomeSection
    @State private var counts = FilterCounts()
    private let isNew: Bool

    init(section: CustomHomeSection, isNew: Bool) {
        _section = State(initialValue: section)
        self.isNew = isNew
    }

    var body: some View {
        List {
            Section {
                TextField("Shelf name", text: $section.name)
                Picker("Made of", selection: $section.filter.subject) {
                    Text("Albums").tag(LibraryFilter.Subject.albums)
                    Text("Songs").tag(LibraryFilter.Subject.songs)
                }
            }

            GroupEditor(
                group: $section.filter.root,
                subject: section.filter.subject,
                counts: counts
            )

            Section {
                LabeledContent("Matches") {
                    if let total = counts.total {
                        Text(total.formatted() + (section.showsAlbums ? " albums" : " songs"))
                            .foregroundStyle(total == 0 ? .red : .secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
            } footer: {
                if section.filter.isEmpty {
                    Text("With no rules, this shelf is your whole library.")
                }
            }

            Section {
                Toggle("Only the first few", isOn: Binding(
                    get: { section.limit != nil },
                    set: { section.limit = $0 ? (section.limit ?? 100) : nil }
                ))
                if let limit = section.limit {
                    // A stepper rather than a field: these are round numbers,
                    // and a keyboard over a settings list to type "100" is
                    // more asking than the question deserves.
                    Stepper(
                        value: Binding(
                            get: { limit },
                            set: { section.limit = $0 }
                        ),
                        in: Self.limitRange,
                        step: Self.limitStep
                    ) {
                        LabeledContent("Keep", value: limit.formatted())
                    }
                }
            } header: {
                Text("How many")
            }
        }
        .navigationTitle(isNew ? "New Shelf" : "Edit Shelf")
        .navigationBarTitleDisplayMode(.inline)
        // The same rule rows as the filter sheet, and the same reason — see
        // the note on `LibraryFilterSheet`.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
            }
        }
        // Recounted as the filter changes, which is the only way to tell
        // whether the rules say what you meant before you go and look.
        .task(id: section.filter) { await recount() }
        // Switching between records and songs can strand a rule about a field
        // the other one does not have.
        .onChange(of: section.filter.subject) { _, subject in
            section.filter.root = Self.pruned(section.filter.root, for: subject)
        }
    }

    private static let limitRange = 5...500
    private static let limitStep = 5

    private func recount() async {
        counts = FilterCounts()
        // A moment's pause, so the counts are not run for every keystroke of
        // a title being typed into a rule.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let index = app.libraryIndex else { return }
        let filter = section.filter
        let downloadedOnly = app.isOffline
        // Off the main actor: one count per rule and per group is a handful
        // of queries, and they are not worth a frame of the editor.
        func measure() async -> FilterCounts {
            await Task.detached(priority: .userInitiated) {
                FilterCounts.measure(filter, using: index, downloadedOnly: downloadedOnly)
            }.value
        }

        counts = await measure()
        guard !Task.isCancelled else { return }

        // A playlist rule is answered out of a table filled a few playlists at a time, so the first
        // answer is only what has arrived so far — and for a shelf nobody had opened before, that
        // is nothing at all.
        while await app.fillPlaylistMembership(askedBy: filter) {
            guard !Task.isCancelled else { return }
            counts = await measure()
        }
    }

    private func save() {
        // Both halves of saving a shelf — see `AppModel.saveCustomSection`,
        // which is where the placing-on-Home half lives now that the filter
        // sheet needs it too.
        app.saveCustomSection(section)
        dismiss()
    }

    /// Drops rules that the chosen subject has no answer for.
    private static func pruned(_ group: FilterGroup, for subject: LibraryFilter.Subject) -> FilterGroup {
        var pruned = group
        pruned.children = group.children.compactMap { node -> FilterNode? in
            switch node {
            case .rule(let rule):
                return rule.field.applies(to: subject) ? node : nil
            case .group(let inner):
                return .group(self.pruned(inner, for: subject))
            }
        }
        return pruned
    }
}

/// How much of the library each part of a filter finds.
struct FilterCounts: Equatable {
    var total: Int?
    var byNode: [UUID: Int] = [:]

    /// Runs on whatever thread asks: the index is `Sendable` and each of these is one `COUNT(*)`,
    /// but there is one per rule and per group, and a filter being typed into recounts on every
    /// keystroke that settles.
    static func measure(
        _ filter: LibraryFilter,
        using index: LibraryIndex,
        downloadedOnly: Bool,
        within ids: [MediaID]? = nil,
        page: AlbumFilter? = nil
    ) -> FilterCounts {
        var counts = FilterCounts()
        counts.total = try? index.count(
            matching: filter, downloadedOnly: downloadedOnly, within: ids, page: page
        )

        var running: [FilterNode] = []
        for node in filter.root.children {
            let asked: FilterGroup
            switch node {
            case .rule:
                running.append(node)
                asked = FilterGroup(match: filter.root.match, children: running)
            case .group(let inner):
                asked = inner
            }
            counts.byNode[node.id] = try? index.count(
                matching: LibraryFilter(subject: filter.subject, root: asked),
                downloadedOnly: downloadedOnly, within: ids, page: page
            )
        }
        return counts
    }
}

/// Found by id rather than held by position: a row whose rule is deleted while
/// SwiftUI still holds an index into the old array reads its neighbour, or
/// walks off the end of the last one.
private extension Binding where Value == FilterGroup {
    func ruleBinding(_ id: UUID) -> Binding<FilterRule> {
        Binding<FilterRule>(
            get: {
                guard let node = wrappedValue.children.first(where: { $0.id == id }),
                      case .rule(let rule) = node
                else { return FilterRule(field: .title, op: .contains) }
                return rule
            },
            set: { new in
                guard let index = wrappedValue.children.firstIndex(where: { $0.id == id })
                else { return }
                wrappedValue.children[index] = .rule(new)
            }
        )
    }

    func groupBinding(_ id: UUID) -> Binding<FilterGroup> {
        Binding<FilterGroup>(
            get: {
                guard let node = wrappedValue.children.first(where: { $0.id == id }),
                      case .group(let group) = node
                else { return FilterGroup() }
                return group
            },
            set: { new in
                guard let index = wrappedValue.children.firstIndex(where: { $0.id == id })
                else { return }
                wrappedValue.children[index] = .group(new)
            }
        )
    }
}

private extension FilterGroup {
    var ruleIDs: [UUID] {
        children.compactMap { if case .rule(let rule) = $0 { rule.id } else { nil } }
    }

    var groupIDs: [UUID] {
        children.compactMap { if case .group(let group) = $0 { group.id } else { nil } }
    }
}

/// The filter, read down the page: the line saying whether all or any of it has to match, the rules
/// standing loose under it, and then each group as a box of its own beneath them.
struct GroupEditor: View {
    /// For the fields this server can actually answer — see
    /// `FilterField.isAnswerable(by:)`.
    @Environment(AppModel.self) private var app

    @Binding var group: FilterGroup
    let subject: LibraryFilter.Subject
    var counts = FilterCounts()

    var body: some View {
        Section {
            MatchPicker(match: $group.match)

            ForEach(group.ruleIDs, id: \.self) { id in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    RuleEditor(rule: $group.ruleBinding(id), subject: subject)
                    Spacer(minLength: 0)
                    MatchCount(count: counts.byNode[id])
                }
            }
            .onDelete { offsets in
                let going = Set(offsets.map { group.ruleIDs[$0] })
                group.children.removeAll { going.contains($0.id) }
            }

            Button {
                group.children.append(.rule(Self.newRule(for: subject, on: app.expectedCapabilities)))
            } label: {
                Label("Add Rule", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }

            Button {
                group.children.append(.group(FilterGroup(match: .any)))
            } label: {
                Label("Add Group", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        } header: {
            Text("Rules")
        }

        ForEach(group.groupIDs, id: \.self) { id in
            FilterGroupBox(
                group: $group.groupBinding(id),
                subject: subject,
                count: counts.byNode[id],
                remove: { group.children.removeAll { $0.id == id } }
            )
        }
    }

    /// Takes the capabilities rather than reading them: a new rule starts on
    /// the first field the list offers, and which fields it offers depends on
    /// the server — see `FilterField.isAnswerable(by:)`.
    static func newRule(
        for subject: LibraryFilter.Subject,
        on capabilities: ServerCapabilities
    ) -> FilterRule {
        let field = FilterField.fields(for: subject, on: capabilities).first ?? .title
        return FilterRule(
            field: field,
            op: FilterOperator.operators(for: field).first ?? .contains,
            value: RuleEditor.startingValue(for: field)
        )
    }
}

/// One group, drawn as its own box below the rules rather than inside them,
/// with what it finds on its own written under it.
private struct FilterGroupBox: View {
    @Environment(AppModel.self) private var app

    @Binding var group: FilterGroup
    let subject: LibraryFilter.Subject
    let count: Int?
    let remove: () -> Void

    var body: some View {
        Section {
            MatchPicker(match: $group.match)

            ForEach(group.ruleIDs, id: \.self) { id in
                RuleEditor(rule: $group.ruleBinding(id), subject: subject)
            }
            .onDelete { offsets in
                let going = Set(offsets.map { group.ruleIDs[$0] })
                group.children.removeAll { going.contains($0.id) }
            }

            // Groups within groups cannot be made any more, but a filter
            // built before they could not still holds one, and a rule nobody
            // can reach is worse than a page nobody will open.
            ForEach(group.groupIDs, id: \.self) { id in
                NavigationLink {
                    LegacyGroupView(group: $group.groupBinding(id), subject: subject)
                } label: {
                    LabeledContent("Group", value: legacyDescription(id))
                }
            }

            Button {
                group.children.append(.rule(GroupEditor.newRule(for: subject, on: app.expectedCapabilities)))
            } label: {
                Label("Add Rule", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
        } header: {
            HStack {
                Text("Group")
                Spacer()
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove group")
            }
        } footer: {
            if let count {
                Text("\(count.formatted()) \(subject == .albums ? "albums" : "songs")")
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func legacyDescription(_ id: UUID) -> String {
        guard let node = group.children.first(where: { $0.id == id }),
              case .group(let inner) = node
        else { return "" }
        return "\(inner.match.title) of \(inner.children.count.counted("rule"))"
    }
}

/// A group that a filter already had inside another group, on its own page —
/// see the note at its only remaining call site.
private struct LegacyGroupView: View {
    @Environment(AppModel.self) private var app

    @Binding var group: FilterGroup
    let subject: LibraryFilter.Subject

    var body: some View {
        List {
            Section {
                MatchPicker(match: $group.match)

                ForEach(group.ruleIDs, id: \.self) { id in
                    RuleEditor(rule: $group.ruleBinding(id), subject: subject)
                }
                .onDelete { offsets in
                    let going = Set(offsets.map { group.ruleIDs[$0] })
                    group.children.removeAll { going.contains($0.id) }
                }

                Button {
                    group.children.append(.rule(GroupEditor.newRule(for: subject, on: app.expectedCapabilities)))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            } header: {
                Text("Group")
            }
        }
        .navigationTitle("Group")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MatchPicker: View {
    @Binding var match: FilterGroup.Match

    var body: some View {
        Picker("Match", selection: $match) {
            Text("all of these").tag(FilterGroup.Match.all)
            Text("any of these").tag(FilterGroup.Match.any)
        }
        .pickerStyle(.segmented)
    }
}

/// The number beside a rule — compact, because nobody reads the last three
/// digits of a library and "9.8K" is the shape the eye is comparing.
private struct MatchCount: View {
    let count: Int?

    var body: some View {
        if let count {
            Text(count.formatted(.number.notation(.compactName)))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(count == 0 ? Color.red : Color.secondary)
        }
    }
}

/// One rule: a field, what to do with it, and the value to compare against.
private struct RuleEditor: View {
    @Environment(AppModel.self) private var app

    @Binding var rule: FilterRule
    let subject: LibraryFilter.Subject

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Menus with plain text labels rather than `Picker`s.
            HStack(spacing: 14) {
                fieldMenu
                testMenu

                // Soaks up the rest of the line so neither menu grows into
                // it, and so nothing sits under the empty space to the right
                // of them.
                Spacer(minLength: 0)
            }
            // A different rule is a different row, not the same row growing into a new width.
            .id(rule.field)
            .id(rule.op)
            if rule.op.needsValue {
                valueEditor
            }
        }
        .padding(.vertical, 2)
        // A rule is a sentence being read, not a thing to animate: it changes the instant it is
        // chosen.
        .transaction { $0.animation = nil }
        // A field of one kind cannot keep a test or a value meant for
        // another: "contains" makes no sense of a rating.
        .onChange(of: rule.field) { old, new in
            // A field that trims the list of tests can leave the rule holding one it does not offer
            // — swapping the track title for the playlist name kept "is", which then asked whether
            // the song's playlists, run together, were exactly that name.
            let allowed = FilterOperator.operators(for: new)
            if !allowed.contains(rule.op) {
                rule.op = allowed.first ?? .contains
            }
            guard old.kind != new.kind else { return }
            rule.value = Self.startingValue(for: new)
        }
        .onChange(of: rule.op) { _, op in
            // "In the last —" counts days; "before" needs a date. Swapping
            // between them has to swap the value with it.
            switch op {
            case .inTheLast, .notInTheLast:
                if case .days = rule.value {} else { rule.value = .days(30) }
            case .before, .after:
                if case .date = rule.value {} else { rule.value = .date(Date()) }
            default:
                break
            }
        }
    }

    /// A menu's label: the chosen value and a chevron, and nothing around them — so it starts
    /// exactly where the value field below it does.
    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 3) {
            Text(text)
                // On a narrow enough screen even one of these alone can outrun the line, and a name
                // cut short with an ellipsis still reads as a name — clipped mid word it reads as a
                // broken screen.
                .lineLimit(1)
                .truncationMode(.tail)
                // The words are swapped, not morphed into one another.
                .contentTransition(.identity)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
                .imageScale(.small)
                // Never the thing that gives way: without this the chevron is
                // squeezed out before the text is, and the menu stops looking
                // like something you can tap.
                .fixedSize()
        }
        .contentShape(Rectangle())
        // And the box itself does not grow, it is simply the new size.
        .transaction { $0.animation = nil }
    }

    private var fieldMenu: some View {
        Menu {
            Picker("Field", selection: $rule.field) {
                ForEach(FilterField.fields(for: subject, on: app.expectedCapabilities)) { field in
                    Text(field.title(for: subject)).tag(field)
                }
            }
        } label: {
            menuLabel(rule.field.title(for: subject))
        }
    }

    private var testMenu: some View {
        Menu {
            Picker("Test", selection: $rule.op) {
                ForEach(FilterOperator.operators(for: rule.field)) { op in
                    Text(op.title(for: rule.field)).tag(op)
                }
            }
        } label: {
            menuLabel(rule.op.title(for: rule.field))
        }
    }

    /// Every half star the servers can store, best first.
    private static let ratingSteps: [Double] = [5, 4.5, 4, 3.5, 3, 2.5, 2, 1.5, 1, 0.5]

    /// "★★★½" — the same way the rating menus write it.
    private static func stars(_ value: Double) -> String {
        let whole = Int(value)
        let text = String(repeating: "★", count: whole)
        if value > Double(whole) { return whole == 0 ? "½" : text + "½" }
        return text
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch rule.field.kind {
        case .text:
            TextField(rule.field.title(for: subject), text: textBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .filterValueLine()
        case .number:
            HStack {
                TextField("Value", value: numberBinding, format: .number)
                    // Every other `.number` field is whole by nature — a year, a track number, a
                    // play count.
                    .keyboardType(rule.field == .criticRating ? .decimalPad : .numberPad)
                    .filterValueLine()
                if rule.field == .duration {
                    Text("seconds").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .rating:
            // Half steps, because the servers store them and a library full of two-and-a-half-star
            // songs cannot be asked about in whole ones.
            Picker("Stars", selection: numberBinding) {
                ForEach(Self.ratingSteps, id: \.self) { stars in
                    Text(Self.stars(stars)).tag(stars)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
        case .date:
            switch rule.op {
            case .inTheLast, .notInTheLast:
                HStack {
                    TextField("Number", value: periodCountBinding, format: .number)
                        .keyboardType(.numberPad)
                        .filterValueLine()
                    // The unit was a fixed caption reading "days", so "not played in the last two
                    // years" had to be entered as 730.
                    Picker("Unit", selection: periodUnitBinding) {
                        ForEach(FilterPeriod.allCases) { unit in
                            Text(unit.title(count: periodCountBinding.wrappedValue)).tag(unit)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            default:
                DatePicker("Date", selection: dateBinding, displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
            }
        case .flag:
            EmptyView()
        }
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { if case .text(let text) = rule.value { text } else { "" } },
            set: { rule.value = .text($0) }
        )
    }

    private var numberBinding: Binding<Double> {
        Binding(
            get: { if case .number(let number) = rule.value { number } else { 0 } },
            set: { rule.value = .number($0) }
        )
    }

    /// The rule stores days and only days — see `FilterPeriod`. These two
    /// take it apart into a number and a unit for the length of the edit and
    /// put it back together again on every keystroke.
    private var spelled: (count: Int, unit: FilterPeriod) {
        guard case .days(let days) = rule.value else { return (30, .days) }
        return FilterValue.spelled(days: days)
    }

    private var periodCountBinding: Binding<Int> {
        Binding(
            get: { spelled.count },
            set: { rule.value = .days(count: $0, unit: spelled.unit) }
        )
    }

    private var periodUnitBinding: Binding<FilterPeriod> {
        Binding(
            get: { spelled.unit },
            // The number stands and the unit changes under it: picking months
            // after typing 3 means three months, not ninety days re-read as
            // three of something else.
            set: { rule.value = .days(count: spelled.count, unit: $0) }
        )
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { if case .date(let date) = rule.value { date } else { Date() } },
            set: { rule.value = .date($0) }
        )
    }

    /// What a rule starts at when its field is chosen.
    static func startingValue(for field: FilterField) -> FilterValue {
        switch field.kind {
        case .text: .text("")
        case .rating: .number(4)
        case .date: .days(30)
        case .flag: .none
        case .number:
            switch field {
            case .year: .number(1990)
            case .duration: .number(180)
            default: .number(1)
            }
        }
    }
}

extension View {
    /// A rule's value field, tappable across the whole line rather than only where its text happens
    /// to sit.
    func filterValueLine() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}
