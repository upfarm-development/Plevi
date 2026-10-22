import SwiftUI
import PleviDomain

/// Where "Archive" on the Spotlight card goes — every artist it has ever
/// picked, most recent first, so a good week is never lost the moment the
/// next one replaces it on Home.
struct SpotlightArchiveRoute: Hashable {
    let history: [SpotlightStore.HistoryEntry]
}

struct SpotlightArchiveView: View {
    let history: [SpotlightStore.HistoryEntry]

    @Environment(AppModel.self) private var app

    var body: some View {
        List(history) { entry in
            if let artist = resolve(entry) {
                NavigationLink(value: artist) {
                    row(for: entry, artist: artist)
                }
            } else {
                // Left in the list rather than dropped silently: it is
                // still a true record of what was shown, even for an
                // artist since removed from the library.
                row(for: entry, artist: nil)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Spotlight Archive")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if history.isEmpty {
                ContentUnavailableView(
                    "No Spotlights Yet",
                    systemImage: "star",
                    description: Text("Artists spotlighted on Home will be kept here.")
                )
            }
        }
    }

    private func row(for entry: SpotlightStore.HistoryEntry, artist: Artist?) -> some View {
        HStack(spacing: 14) {
            ArtworkView(artwork: artist?.artwork, size: 48, placeholder: .artist)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.artistName)
                    .font(.system(size: 16, weight: .semibold))
                if let date = Spotlight.date(forWeek: entry.week) {
                    Text(Self.weekLabel(for: date))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
    }

    private func resolve(_ entry: SpotlightStore.HistoryEntry) -> Artist? {
        guard let index = app.libraryIndex else { return nil }
        return try? index.artist(id: MediaID(server: index.server, rawValue: entry.artistID))
    }

    private static func weekLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return "Week of \(formatter.string(from: date))"
    }
}
