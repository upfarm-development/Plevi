import SwiftUI
import PleviDomain

/// What a long press offers.
struct HoldActions: Identifiable {
    enum Subject {
        case track(Track)
        case album(Album)
        case artist(Artist)
        case playlist(Playlist)
    }

    let id = UUID()
    let subject: Subject
    /// The songs the action applies to, worked out by whoever raised the
    /// sheet — a record knows its own tracks, and an artist's take a query.
    let tracks: () async -> [Track]
    /// Raised from a Downloads page, where Play Next and Add to Queue must not put songs on the
    /// queue that are not on this watch — each one would stream from an unreachable server and
    /// fail, or stall until its timeout.
    var downloadedOnly = false

    var title: String {
        switch subject {
        case .track(let track): track.displayTitle
        case .album(let album): album.displayName
        case .artist(let artist): artist.name
        case .playlist(let playlist): playlist.name
        }
    }

    /// Why these songs would be kept, or nil for a subject that is not a
    /// thing you download.
    var reason: DownloadReason? {
        switch subject {
        case .track: nil
        case .album(let album): .album(album.id)
        case .artist(let artist): .artist(artist.id)
        case .playlist(let playlist): .playlist(playlist.id)
        }
    }

    /// The playlist itself, which has to be written down whole rather than as
    /// a set of songs — offline there is nothing to ask what it was called or
    /// what order it went in.
    var playlist: Playlist? {
        if case .playlist(let playlist) = subject { return playlist }
        return nil
    }
}

/// The sheet itself: the two queue actions every subject has, plus whatever
/// the subject adds.
struct HoldSheet: View {
    let actions: HoldActions
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Whether the one destructive action here is waiting to be confirmed.
    /// Raised by the button and presented by the sheet, so the dialog does
    /// not go when the button that asked for it does.
    @State private var isConfirmingRemove = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(actions.title)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                    model.player.playNext(await playable())
                }
                button("Add to Queue", systemImage: "text.append") {
                    model.player.addToQueue(await playable())
                }
                // A song on its own is not offered for download: a watch full
                // of single songs is a library nobody can find their way
                // around. Records, artists and playlists are the units.
                if let reason = actions.reason {
                    if model.downloads?.isRequested(reason) == true {
                        // The only one of the app's destructive actions that never asked — and it
                        // deletes the most.
                        button("Remove Download", systemImage: "trash", closesSheet: false) {
                            isConfirmingRemove = true
                        }
                    } else {
                        button("Download", systemImage: "arrow.down.circle") {
                            await model.download(actions)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .confirmationDialog(
            "Remove \(actions.title) from this watch?",
            isPresented: $isConfirmingRemove,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                guard let reason = actions.reason else { return }
                Task {
                    await removeDownload(reason)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing on the server is touched.")
        }
    }

    /// The songs the queue actions apply to: all of them, or only the ones on
    /// this watch when the hold was raised in Downloads.
    private func playable() async -> [Track] {
        let all = await actions.tracks()
        guard actions.downloadedOnly, let library = model.library else { return all }
        return PlayableSongs.filter(all, downloaded: library.downloadedTrackIDs())
    }

    /// Takes off this watch everything the hold was raised on.
    private func removeDownload(_ reason: DownloadReason) async {
        let ids: [MediaID]
        if case .playlist(let id) = reason,
           case let kept = model.memberIDs(inDownloadedPlaylist: id),
           !kept.isEmpty {
            ids = kept
        } else {
            ids = await actions.tracks().map(\.id)
        }
        model.downloads?.remove(reason: reason, tracks: ids)
    }

    /// - Parameter closesSheet: whether the sheet goes when this is tapped.
    ///   Only the one that raises a confirmation stays, because the dialog is
    ///   presented by the sheet and would go with it.
    private func button(
        _ title: String,
        systemImage: String,
        closesSheet: Bool = true,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task {
                await action()
                if closesSheet { dismiss() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                Spacer(minLength: 0)
            }
            .frame(minHeight: WatchMetrics.row)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: WatchMetrics.corner, style: .continuous))
    }
}

extension View {
    /// A hold that does not fight the scroll.
    func onHold(perform action: @escaping () -> Void) -> some View {
        simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in action() }
        )
    }
}

/// Play and Shuffle at the top of a record, an artist or a playlist.
struct PlayShuffleRow: View {
    let onPlay: () -> Void
    let onShuffle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: WatchMetrics.pill)
            }
            .buttonStyle(.plain)
            .background(.tint, in: Capsule())

            Button(action: onShuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.system(size: 16, weight: .semibold))
                    .labelStyle(.iconOnly)
                    .frame(width: 62, height: WatchMetrics.pill)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.16), in: Capsule())
            .accessibilityLabel("Shuffle")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 6, trailing: 0))
    }
}
