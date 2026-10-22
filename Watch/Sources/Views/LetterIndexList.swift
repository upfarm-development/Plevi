import SwiftUI
import PleviDomain

/// Where a library is picked apart by letter before it is scrolled.
struct LetterScope: Hashable {
    enum Kind: Hashable { case artists, albums }

    let kind: Kind
    /// The letter as it is drawn — see `AlphabetIndex`.
    let bucket: String
    /// The first characters that file under it, which is what the index is
    /// actually asked for: upper and lower case, and every accented form the
    /// library happens to hold.
    let initials: Set<String>
    let downloadedOnly: Bool
}

struct LetterIndexList: View {
    let kind: LetterScope.Kind
    let downloadedOnly: Bool

    @Environment(WatchModel.self) private var model
    @State private var counts: [String: Int] = [:]
    @State private var buckets: [(bucket: String, count: Int)] = []
    /// Whether the counts above are the real answer yet.
    @State private var hasLoaded = false

    /// Above this many rows the letters are worth a screen of their own.
    /// Below it they are a detour.
    private static let worthIndexing = 120

    private var total: Int { counts.values.reduce(0, +) }

    var body: some View {
        Group {
            if !hasLoaded {
                loading
            } else if counts.isEmpty {
                loadingOrEmpty
            } else if total <= Self.worthIndexing {
                plainList
            } else {
                grid
            }
        }
        .task(id: model.libraryVersion + model.downloadsRefreshKey(downloadedOnly)) {
            if downloadedOnly, hasLoaded {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            guard let library = model.library else { return }
            counts = switch kind {
            case .artists: library.artistInitials(downloadedOnly: downloadedOnly)
            case .albums: library.albumInitials(downloadedOnly: downloadedOnly)
            }
            buckets = Self.sections(from: counts)
            hasLoaded = true
        }
    }

    private var loading: some View {
        List {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle(title)
    }

    /// The whole list, when there is not enough of it to be worth a letter.
    @ViewBuilder
    private var plainList: some View {
        switch kind {
        case .artists: ArtistsList(downloadedOnly: downloadedOnly)
        case .albums: AlbumsList(downloadedOnly: downloadedOnly, filter: .all)
        }
    }

    @ViewBuilder
    private var loadingOrEmpty: some View {
        List {
            WatchEmptyView(
                title: emptyTitle,
                systemImage: kind == .artists ? "music.mic" : "square.stack"
            )
        }
        .navigationTitle(title)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 44), spacing: 6)],
                spacing: 6
            ) {
                ForEach(buckets, id: \.bucket) { each in
                    NavigationLink(value: scope(for: each.bucket)) {
                        Text(each.bucket)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    // The count is what makes a letter worth pressing or not,
                    // and it is the only thing on this screen that says how
                    // much of the library there is.
                    .accessibilityLabel("\(each.bucket), \(each.count.counted(unit))")
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationTitle(title)
        .watchDownloadRing(model.downloads)
    }

    private func scope(for bucket: String) -> LetterScope {
        LetterScope(
            kind: kind,
            bucket: bucket,
            initials: Set(counts.keys.filter { AlphabetIndex.section(for: $0) == bucket }),
            downloadedOnly: downloadedOnly
        )
    }

    /// The letters that have something behind them, in bar order.
    static func sections(from counts: [String: Int]) -> [(bucket: String, count: Int)] {
        var totals: [String: Int] = [:]
        for (character, count) in counts {
            totals[AlphabetIndex.section(for: character), default: 0] += count
        }
        return totals
            .map { (bucket: $0.key, count: $0.value) }
            .sorted { AlphabetIndex.rank(ofSection: $0.bucket) < AlphabetIndex.rank(ofSection: $1.bucket) }
    }

    private var unit: String { kind == .artists ? "artist" : "record" }

    private var title: String { kind == .artists ? "Artists" : "Albums" }

    private var emptyTitle: String {
        switch (kind, downloadedOnly) {
        case (.artists, true): "No artists downloaded"
        case (.artists, false): "No artists"
        case (.albums, true): "Nothing downloaded"
        case (.albums, false): "No records"
        }
    }
}
