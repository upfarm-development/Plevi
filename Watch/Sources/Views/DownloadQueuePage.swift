import SwiftUI
import PleviDomain

/// What is still coming, in the order it will arrive.
struct DownloadQueuePage: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Read into state rather than from the body.
    @State private var songs: [WatchDownloads.QueuedSong] = []
    /// Whether the first snapshot has been taken. `.task` runs after the
    /// first frame, so without this the page opened on "Nothing queued" for a
    /// frame with thirty songs behind it.
    @State private var hasLoaded = false
    /// Raised by a row, presented by the page — the pattern every other list here follows, and for
    /// a reason this list makes sharper than most: rows leave the queue whenever a song lands, and
    /// a dialog owned by a row goes with it, out from under…
    @State private var dropping: WatchDownloads.QueuedSong?

    var body: some View {
        List {
            if let downloads = model.downloads {
                // Only while something is owed.
                if downloads.queueCount > 0 {
                    QueueControlsRow(downloads: downloads)
                    QueueSummaryRow(downloads: downloads)
                }
                if songs.isEmpty, hasLoaded {
                    WatchEmptyView(
                        title: "Nothing queued",
                        detail: "Songs on their way to this watch show up here.",
                        systemImage: "arrow.down.circle"
                    )
                }
                ForEach(songs) { song in
                    QueuedSongRow(song: song, downloads: downloads)
                        .onHold { dropping = song }
                }
                // Underneath everything, where Settings puts Clear Downloads.
                if downloads.queueCount > 0 {
                    ClearQueueRow(downloads: downloads)
                }
            }
        }
        .navigationTitle("Download Queue")
        .task(id: model.downloads?.queueKey ?? "none") {
            songs = model.downloads?.queue ?? []
            hasLoaded = true
        }
        // Away when the work is, the way the sheet this replaced took itself
        // away. Staying would leave somebody looking at controls for a queue
        // that no longer exists.
        .onChange(of: model.downloads?.queueCount ?? 0) { _, owed in
            if owed == 0, hasLoaded { dismiss() }
        }
        .confirmationDialog(
            dropping?.title ?? "",
            isPresented: Binding(
                get: { dropping != nil },
                set: { if !$0 { dropping = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Don't Download This", role: .destructive) {
                if let song = dropping { model.downloads?.drop(song.id) }
                dropping = nil
            }
            Button("Cancel", role: .cancel) { dropping = nil }
        }
    }
}

/// Stop, or start again, and the way to give up on the whole queue.
private struct QueueControlsRow: View {
    let downloads: WatchDownloads

    var body: some View {
        HStack(spacing: 8) {
            if downloads.isPaused || downloads.isStalled {
                // One button for two quite different situations, deliberately.
                Button {
                    Task { await downloads.startQueue() }
                } label: {
                    pill("Start Again", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .background(.tint, in: Capsule())
            } else {
                // Pause, and it looks like one.
                Button {
                    downloads.pauseQueue()
                } label: {
                    pill("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.plain)
                .background(.white.opacity(0.16), in: Capsule())
            }
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
    }

    private func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: WatchMetrics.pill)
    }
}

/// What the batch is called and how far it has got.
private struct QueueSummaryRow: View {
    let downloads: WatchDownloads

    var body: some View {
        Text(line)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .listRowBackground(Color.clear)
    }

    private var line: String {
        let count = downloads.queueHeadline ?? ""
        let progress: String
        if let title = downloads.runningTitle {
            progress = "\(title) · \(count)"
        } else {
            progress = count
        }
        // Why the queue stopped itself, when it did: a full watch or a
        // sign-in page, which every other song would hit as well.
        guard let held = downloads.holdMessage else { return progress }
        return progress.isEmpty ? held : "\(progress)\n\(held)"
    }
}

/// Giving up on the whole queue, at the bottom of it.
private struct ClearQueueRow: View {
    let downloads: WatchDownloads

    @State private var isConfirming = false

    var body: some View {
        Button(role: .destructive) {
            isConfirming = true
        } label: {
            Label("Clear Queue", systemImage: "trash")
                .font(.system(size: 15))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: WatchMetrics.row)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .listRowBackground(Color.clear)
        // The only control here that asks, because it is the only one that cannot be undone.
        .confirmationDialog(
            "Clear the download queue?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Clear Queue", role: .destructive) { downloads.clearQueue() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The songs already on this watch stay.")
        }
    }
}

/// One song waiting its turn.
private struct QueuedSongRow: View {
    let song: WatchDownloads.QueuedSong
    let downloads: WatchDownloads

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.system(size: 16))
                        .lineLimit(1)
                    if let artist = song.artist {
                        Text(artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                // Only the song being worked on says anything here.
                if song.isLeading {
                    SongPercentage(id: song.id, downloads: downloads)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            // Below the pair of them and the full width of the row, so its length means how far the
            // song has got and nothing else.
            if song.isLeading {
                SongProgress(id: song.id, downloads: downloads)
            }
        }
        .frame(minHeight: WatchMetrics.track)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The bar for the one song being fetched.
private struct SongProgress: View {
    let id: MediaID
    let downloads: WatchDownloads

    var body: some View {
        Group {
            if let fraction = downloads.fraction(for: id) {
                ProgressView(value: fraction)
            } else {
                // Moving, with nothing honest to say about how far. A bar
                // pinned at nothing reads as a download that is stuck, which
                // is the opposite of the truth.
                ProgressView()
            }
        }
        // Both the same shape, or the row changes height the moment a song
        // gains or loses a denominator.
        .progressViewStyle(.linear)
        .tint(.accentColor)
    }
}

/// The same number in words, for the trailing edge of the row.
private struct SongPercentage: View {
    let id: MediaID
    let downloads: WatchDownloads

    var body: some View {
        Text(downloads.fraction(for: id).map { "\(Int($0 * 100))%" } ?? "…")
            .font(.system(size: 13))
            // Without this the row twitches as the digits change width, which
            // on a wrist reads as the list redrawing rather than as the song
            // getting closer.
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
