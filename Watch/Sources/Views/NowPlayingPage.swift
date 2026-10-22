import SwiftUI
import PleviDomain

/// The playing screen: the sleeve, what it is, where you are in it, and the three controls that
/// matter.
struct NowPlayingPage: View {
    @Environment(WatchModel.self) private var model
    @State private var wash: Color?
    /// The sleeve, for the backdrop — see `backdrop`.
    @State private var art: UIImage?
    @State private var showingUpNext = false
    /// Whether this is the page currently on screen — see `WatchVolumeControl`.
    let isActive: Bool

    private var player: WatchPlayer { model.player }

    var body: some View {
        Group {
            if let track = player.currentTrack {
                playing(track)
            } else {
                idle
            }
        }
        // The control itself is only here to claim the crown, so it is kept out of sight — its own
        // dial would stand on the screen for the whole of every song to answer a question asked
        // once in a while.
        .overlay(alignment: .topLeading) {
            WatchVolumeControl(isActive: isActive)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        // What is actually shown, and only while the volume is moving.
        .overlay(alignment: .topLeading) {
            if isActive {
                VolumeHUD()
                    .offset(y: -18)
                    .padding(.leading, 6)
            }
        }
        .background { backdrop }
        .sheet(isPresented: $showingUpNext) { UpNextSheet() }
        .task(id: artworkKey) { await loadArtwork() }
    }

    /// What has to change before the backdrop is worth fetching again: the sleeve, and whether
    /// there is anything to fetch it with.
    private var artworkKey: String {
        "\(player.currentTrack?.artwork?.rawValue ?? "")-\(model.connectionKey)"
    }

    /// The record itself, filling the screen and thrown out of focus.
    @ViewBuilder
    private var backdrop: some View {
        if let art {
            // The size is measured and handed over, rather than inherited.
            GeometryReader { proxy in
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .blur(radius: 22, opaque: true)
                    .overlay(.black.opacity(0.45))
                    .clipped()
            }
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: art)
        } else if let wash {
            // Until the picture is here, for a record that has none, and for
            // a watch that cannot reach the server to fetch one — see
            // `loadArtwork`, which takes this from the row-sized sleeve.
            RadialGradient(
                colors: [wash.opacity(0.55), .clear],
                center: .init(x: 0.5, y: 0.26),
                startRadius: 0,
                endRadius: 190
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.4), value: wash)
        }
    }

    private func loadArtwork() async {
        guard let artwork = player.currentTrack?.artwork, let loader = model.artwork else {
            wash = nil
            art = nil
            return
        }
        // The colour first, and from the *small* sleeve — the one the rows have already been
        // through, so it is in memory or on this watch while the big one is still a request over a
        // radio.
        let thumbnail = WatchArtwork.buckets[0]
        wash = loader.cached(artwork, bucket: thumbnail).flatMap(WatchWash.colour(from:))

        // Asked for at the size it is actually drawn now — filling a screen rather than sitting in
        // the middle of one.
        let bucket = WatchArtwork.bucket(forPointSize: 200)
        // `??` takes an autoclosure, which cannot be awaited — so the cache
        // hit and the fetch are separate steps rather than one expression.
        var image = loader.cached(artwork, bucket: bucket)
        if image == nil {
            image = await loader.image(for: artwork, bucket: bucket)
        }
        guard let image else {
            art = nil
            // One more go at the small one before giving up on colour altogether: it checks this
            // watch's own disk before the network, and a watch that has been round its library once
            // has the thumbnail even when the server is out of reach.
            if wash == nil {
                wash = await loader.image(for: artwork, bucket: thumbnail)
                    .flatMap(WatchWash.colour(from:))
            }
            return
        }
        art = image
        wash = WatchWash.colour(from: image)
    }

    private var idle: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Nothing playing")
                .font(.headline)
            // The reason, when there is one.
            if let problem = player.problem {
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            } else {
                Text("Pick a record or a playlist on the next page.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 10)
    }

    /// The words and the controls, over the record rather than under it.
    private func playing(_ track: Track) -> some View {
        playingBody(track)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func playingBody(_ track: Track) -> some View {
        VStack(spacing: 0) {
            // No spacer above the words.
            Spacer(minLength: 12)

            // The phone's, now that both share one — see `MarqueeText`.
            MarqueeText(
                text: track.displayTitle,
                font: .system(size: 17, weight: .semibold),
                // A little slower than the phone's 24: less room to cross,
                // and a wrist is held up for a shorter look.
                speed: 18
                // Not `fillsWidth`.
            )
            .padding(.top, 6)
            Text(albumLine(track))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Holding anywhere on the titles opens the queue. There is no
                // room on this screen for a button that says so, and a hold
                // is what everything else in this app uses for "more".
                .onHold { if !player.upNext.isEmpty { showingUpNext = true } }

            // Above the controls, not below them.
            if let problem = player.problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    // Three lines, not two: these are sentences, and a
                    // truncated one is a reason you cannot act on.
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }

            // What is left over goes here, so the two things you reach for
            // sit at the bottom of the screen rather than wherever the text
            // above them happened to end.
            Spacer(minLength: 8)

            controls
            clock
                .padding(.top, 4)
        }
        .padding(.horizontal, 6)
        // The pager draws its dots along the bottom edge, over whatever is
        // there — so the controls stop above them rather than under them.
        .padding(.bottom, 18)
    }

    private func albumLine(_ track: Track) -> String {
        let album = track.albumName ?? track.artistName ?? ""
        guard let year = track.year else { return album }
        return album.isEmpty ? String(year) : "\(album) · \(year)"
    }

    /// Where you are in the song, and where you are in the queue.
    private var clock: some View {
        HStack {
            Text(WatchTrackRow.length(player.elapsed))
            Spacer()
            Text(remaining)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .padding(.horizontal, 4)
    }

    private var fraction: Double {
        guard let duration = player.duration, duration > 0 else { return 0 }
        return min(max(player.elapsed / duration, 0), 1)
    }

    private var remaining: String {
        guard let duration = player.duration, duration > 0 else { return "--:--" }
        let left = max(0, duration - player.elapsed)
        return "-" + WatchTrackRow.length(left)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.16), in: Circle())

            ZStack {
                // The song's progress, drawn around the button rather than
                // across the screen. Twelve o'clock, clockwise, like every
                // other ring on this watch.
                Circle()
                    .stroke(.white.opacity(0.20), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.5), value: fraction)

                Button { player.togglePlayPause() } label: {
                    Group {
                        if player.isPreparing {
                            ProgressView()
                        } else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 46, height: 46)
                .background(.tint, in: Circle())
            }
            .frame(width: 56, height: 56)

            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .frame(width: 40, height: 40)
            .background(.white.opacity(0.16), in: Circle())
            .disabled(!player.hasNext)
            .opacity(player.hasNext ? 1 : 0.4)
        }
    }
}

/// What is queued after this song.
struct UpNextSheet: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.player.upNext.isEmpty {
                WatchEmptyView(title: "Nothing next", systemImage: "text.append")
            }
            ForEach(model.player.upNext) { item in
                Button {
                    // Tapping a song jumps to it, as the car's queue does.
                    model.player.jump(to: item)
                    dismiss()
                } label: {
                    WatchMediaRow(
                        title: item.track.displayTitle,
                        subtitle: item.track.artistName,
                        artwork: item.track.artwork
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Up Next")
    }
}
