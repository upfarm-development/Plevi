import SwiftUI
import PleviDomain

/// The playing screen's "…" menu.
struct PlayerOverflowMenu: View, Equatable {
    let track: Track?
    let hasLyrics: Bool
    let isSleepTimerActive: Bool
    let hasUpNext: Bool
    let canFavorite: Bool
    let canStartRadio: Bool
    let canAddToPlaylist: Bool
    /// The name of the mix or station playing, or nil for listening that is
    /// not one. What is on a shelf today is gone tomorrow, so this is where
    /// the one you are actually hearing can be kept.
    let mixName: String?
    /// The target's name while controlling it — nil while playing here
    /// ("Disconnect from Kitchen iPad" above
    /// "Stop and Clear Queue").
    let remoteDeviceName: String?
    let glyph: Glyph
    /// The artists `track`'s credit names that the library holds — see
    /// `MediaActions.creditedArtists(for:)`.
    let credited: [Artist]

    /// The two screens draw the same menu behind different buttons: the
    /// artwork-led one sets its own size and tap target, the classic one is
    /// a circled glyph taking the size of the row it sits in.
    enum Glyph: Equatable {
        case bare(Color)
        case circled(Color)
    }

    let onLyrics: () -> Void
    let onSleepTimer: () -> Void
    let onToggleFavorite: (Track) -> Void
    let onStartRadio: (Track) -> Void
    let onAddToPlaylist: (Track) -> Void
    let onSaveMix: () -> Void
    let onNavigate: (AppModel.NavigationRequest) -> Void
    let onClearUpNext: () -> Void
    let onStop: () -> Void
    /// Only called while `remoteDeviceName` is non-nil.
    var onDisconnect: () -> Void = {}

    /// Everything the menu actually draws from, and nothing else.
    nonisolated static func == (lhs: PlayerOverflowMenu, rhs: PlayerOverflowMenu) -> Bool {
        lhs.track == rhs.track
            && lhs.hasLyrics == rhs.hasLyrics
            && lhs.isSleepTimerActive == rhs.isSleepTimerActive
            && lhs.hasUpNext == rhs.hasUpNext
            && lhs.canFavorite == rhs.canFavorite
            && lhs.canStartRadio == rhs.canStartRadio
            && lhs.canAddToPlaylist == rhs.canAddToPlaylist
            && lhs.mixName == rhs.mixName
            && lhs.remoteDeviceName == rhs.remoteDeviceName
            && lhs.glyph == rhs.glyph
            && lhs.credited == rhs.credited
    }

    /// Whether the list of actions is up.
    @State private var offering = false

    var body: some View {
        Button { offering = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityLabel("More")
            .popover(isPresented: $offering, arrowEdge: .bottom) {
                actions
                    .frame(width: 280)
                    .presentationCompactAdaptation(.popover)
            }
    }

    /// The same list of actions a menu held, in a popover instead.
    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track {
                if hasLyrics {
                    row("Lyrics", "quote.bubble", action: onLyrics)
                }
                row(
                    "Sleep Timer",
                    isSleepTimerActive ? "moon.fill" : "moon",
                    action: onSleepTimer
                )
                separator
                if canFavorite {
                    row(
                        track.isFavorite ? "Remove from Favourites" : "Add to Favourites",
                        track.isFavorite ? "heart.slash" : "heart"
                    ) { onToggleFavorite(track) }
                }
                if canStartRadio {
                    row("Song Radio", "dot.radiowaves.left.and.right") { onStartRadio(track) }
                }
                if canAddToPlaylist {
                    row("Add to Playlist…", "text.badge.plus") { onAddToPlaylist(track) }
                }
                // Above the song-level entries it sits beside because it is
                // about the whole of what is playing, not this one track.
                if canAddToPlaylist, mixName != nil {
                    row("Save Mix as Playlist…", "square.stack.badge.plus", action: onSaveMix)
                }
                separator
                if let albumID = track.albumID {
                    row("Go to Album", "square.stack") { onNavigate(.album(albumID)) }
                }
                if credited.count > 1 {
                    Menu {
                        ForEach(credited) { artist in
                            Button(artist.name) {
                                offering = false
                                onNavigate(.artist(artist.id, name: artist.name))
                            }
                        }
                    } label: {
                        rowLabel("Go to Artist", "music.mic")
                    }
                } else if let only = credited.first {
                    row("Go to Artist", "music.mic") { onNavigate(.artist(only.id, name: only.name)) }
                } else if let artistID = track.artistID {
                    row("Go to Artist", "music.mic") { onNavigate(.artist(artistID)) }
                }
                separator
            }
            if hasUpNext {
                row("Clear Up Next", "text.badge.minus", action: onClearUpNext)
            }
            if let remoteDeviceName {
                row("Disconnect from \(remoteDeviceName)", "xmark.circle", action: onDisconnect)
            }
            row("Stop and Clear Queue", "stop.circle", isDestructive: true, action: onStop)
        }
        .padding(.vertical, 6)
        // The page's own wash would otherwise spread onto these glyphs, the
        // same reset the album and playlist menus carry.
        .tint(Color.primary)
    }

    private func row(
        _ title: String,
        _ systemImage: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            // Closed first, so the screen it may push to is not arriving
            // behind a popover still on its way out.
            offering = false
            action()
        } label: {
            rowLabel(title, systemImage, isDestructive: isDestructive)
        }
        .buttonStyle(.plain)
    }

    /// The look every row shares, including "Go to Artist" when it is a
    /// `Menu` rather than a `Button` — a submenu picks its own destination,
    /// but sits in this list looking like everything else in it.
    private func rowLabel(
        _ title: String,
        _ systemImage: String,
        isDestructive: Bool = false
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 16))
            .foregroundStyle(isDestructive ? Color.red : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(.rect)
    }

    private var separator: some View {
        Divider().padding(.vertical, 4)
    }

    @ViewBuilder
    private var label: some View {
        switch glyph {
        case .bare(let color):
            Image(systemName: "ellipsis")
                .font(.system(size: 19))
                .foregroundStyle(color)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        case .circled(let color):
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(color)
        }
    }
}
