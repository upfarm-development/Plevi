import SwiftUI
import PleviDomain
import PleviLibraryIndex

/// Journey's own configuration step — a destination and a length, shown inside the DJ sheet before
/// it activates rather than a separate screen reached from outside it.
struct JourneyDestinationView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onStart: (DJDestination, Int) -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case genre = "Genre"
        case decade = "Decade"
        case track = "Song/Artist"
        var id: String { rawValue }
    }

    @State private var kind: Kind = .genre
    @State private var genres: [Genre] = []
    @State private var decades: [Int] = []
    @State private var selectedGenre: String?
    @State private var selectedDecade: Int?
    @State private var searchText = ""
    @State private var searchResults: [Track] = []
    @State private var selectedTrack: Track?
    @State private var length = 20

    private var destination: DJDestination? {
        switch kind {
        case .genre: selectedGenre.map { .genre($0) }
        case .decade: selectedDecade.map { .decade($0) }
        case .track: selectedTrack.map { .track($0.id, title: $0.title, artist: $0.artistName) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Length") {
                    Picker("Length", selection: $length) {
                        Text("10 songs").tag(10)
                        Text("20 songs").tag(20)
                        Text("30 songs").tag(30)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Picker("Destination kind", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                }

                switch kind {
                case .genre: genreSection
                case .decade: decadeSection
                case .track: trackSection
                }
            }
            .navigationTitle("Journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        guard let destination else { return }
                        onStart(destination, length)
                    }
                    .disabled(destination == nil)
                }
            }
            .task {
                genres = (try? app.libraryIndex?.genres()) ?? []
                decades = (try? app.libraryIndex?.radioDecades()) ?? []
            }
        }
        .withoutBottomScrollEdgeBlur()
    }

    private var genreSection: some View {
        Section("Destination genre") {
            if genres.isEmpty {
                Text("No genres in this library.").foregroundStyle(.secondary)
            }
            ForEach(genres) { genre in
                row(title: genre.name, isOn: selectedGenre == genre.name) {
                    selectedGenre = genre.name
                }
            }
        }
    }

    private var decadeSection: some View {
        Section("Destination decade") {
            if decades.isEmpty {
                Text("No decades resolved in this library.").foregroundStyle(.secondary)
            }
            ForEach(decades, id: \.self) { decade in
                row(title: "\(decade)s", isOn: selectedDecade == decade) {
                    selectedDecade = decade
                }
            }
        }
    }

    private var trackSection: some View {
        Section("Destination song or artist") {
            TextField("Search your library", text: $searchText)
                .onChange(of: searchText) { _, query in search(query) }
            if let selectedTrack {
                row(title: "\(selectedTrack.title) — \(selectedTrack.artistName ?? "")", isOn: true) {
                    self.selectedTrack = nil
                }
            }
            ForEach(searchResults.prefix(20)) { track in
                row(title: track.title, detail: track.artistName, isOn: selectedTrack?.id == track.id) {
                    selectedTrack = track
                    searchText = ""
                    searchResults = []
                }
            }
        }
    }

    private func search(_ query: String) {
        guard let index = app.libraryIndex, query.count >= 2 else {
            searchResults = []
            return
        }
        searchResults = (try? index.search(query, limit: 30, downloadedOnly: app.isOffline))?.tracks ?? []
    }

    private func row(title: String, detail: String? = nil, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
    }
}
