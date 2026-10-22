import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// The rule builder, over a list you are already looking at.
struct LibraryFilterSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    let subject: LibraryFilter.Subject
    /// Applied when Done is pressed, not as you type: a half-written rule
    /// should not keep emptying the list underneath.
    let onApply: (LibraryFilter) -> Void
    /// The page the sheet was opened from, for albums: the records it was
    /// handed outright, or the question it asks of the index. Counts are then
    /// what the filter leaves *there*.
    let within: [MediaID]?
    let page: AlbumFilter?

    @State private var filter: LibraryFilter
    @State private var counts = FilterCounts()

    init(
        subject: LibraryFilter.Subject,
        filter: LibraryFilter,
        within: [MediaID]? = nil,
        page: AlbumFilter? = nil,
        onApply: @escaping (LibraryFilter) -> Void
    ) {
        self.subject = subject
        self.within = within
        self.page = page
        self.onApply = onApply
        var starting = filter
        starting.subject = subject
        _filter = State(initialValue: starting)
    }

    var body: some View {
        NavigationStack {
            List {
                GroupEditor(group: $filter.root, subject: subject, counts: counts)

                Section {
                    LabeledContent("Matches") {
                        if let total = counts.total {
                            Text("\(total.formatted()) \(noun(total))")
                                .foregroundStyle(total == 0 ? .red : .secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                } footer: {
                    if filter.isEmpty {
                        Text("With no rules, this is your whole library.")
                    }
                }

                if !filter.isEmpty {
                    Section {
                        Button("Clear All Rules", role: .destructive) {
                            filter.root = FilterGroup()
                        }
                    }
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onApply(filter)
                        dismiss()
                    }
                }
            }
            .task(id: filter) { await recount() }
        }
        // The hard band rather than the soft one iOS reaches for by default.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .withoutBottomScrollEdgeBlur()
    }

    private func noun(_ count: Int) -> String {
        switch subject {
        case .albums: count == 1 ? "album" : "albums"
        case .songs: count == 1 ? "song" : "songs"
        case .artists: count == 1 ? "artist" : "artists"
        }
    }

    private func recount() async {
        guard let index = app.libraryIndex else { return }
        counts = FilterCounts()
        // A moment's pause, the same one the shelf editor takes.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let asked = filter
        let offline = app.isOffline
        let within = within
        let page = page
        // The count is the promise this sheet makes about the list behind
        // it, so it has to be asking the same question — including fetching
        // the playlists a new rule names. See `fillPlaylistMembership`.
        await app.fillPlaylistMembership(askedBy: asked)
        guard asked == filter else { return }

        func measure() async -> FilterCounts {
            await Task.detached(priority: .userInitiated) {
                FilterCounts.measure(
                    asked, using: index, downloadedOnly: offline, within: within, page: page
                )
            }.value
        }

        counts = await measure()
        guard asked == filter else { return }

        // Those playlists arrive a few at a time — see the same loop in
        // `FilterEditorView.recount`.
        while await app.fillPlaylistMembership(askedBy: asked) {
            guard asked == filter, !Task.isCancelled else { return }
            counts = await measure()
        }
    }
}
