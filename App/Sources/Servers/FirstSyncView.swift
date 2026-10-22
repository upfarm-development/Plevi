import SwiftUI
import PleviLibraryIndex

/// The wait after a server is added, with something to look at and something to read.
struct FirstSyncView: View {
    @Environment(AppModel.self) private var app
    /// Set when someone would rather go in and look around than keep waiting.
    let onSkip: () -> Void

    @State private var pulse = false
    /// How many times the connection has been retried without anyone being
    /// asked. See `quietRetryLimit`.
    @State private var quietRetries = 0

    /// A first connection that fails is very often one that works a moment later — the network
    /// settling after the sign-in, a server still waking, the first request of a new install racing
    /// the radio.
    private static let quietRetryLimit = 2

    private enum Stage: Int, CaseIterable, Identifiable {
        case connecting
        case artists
        case albums
        case tracks
        case finishing

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .connecting: "Reaching your server"
            case .artists: "Artists"
            case .albums: "Albums"
            case .tracks: "Songs"
            case .finishing: "Tidying up"
            }
        }
    }

    /// Where the sync has got to. Connecting is the stage before the engine
    /// starts reporting anything at all.
    private var stage: Stage {
        switch app.syncPhase {
        case .artists: .artists
        case .albums: .albums
        case .tracks: .tracks
        case .finishing: .finishing
        case nil:
            if case .syncing = app.syncState { .artists } else { .connecting }
        }
    }

    /// The engine's own count for a stage: the running one while it is
    /// working, and the last one it gave once it has moved on. A stage that
    /// has done its work should still say how much.
    private func count(for stage: Stage) -> Int? {
        switch stage {
        case .albums: app.syncedAlbums
        case .tracks: app.syncedTracks
        default: nil
        }
    }

    private var failure: String? {
        // Nothing is said while the app is still working on it.
        if app.isRecovering { return nil }
        // The connection before the sync, for the reason `serverUnreachable`
        // gives: an unreachable server is why the sync is not running, and
        // saying so is more use than repeating what the last sync said.
        if case .failed(let message) = app.connection {
            return quietRetries < Self.quietRetryLimit ? nil : message
        }
        if case .failed(let message) = app.syncState { return message }
        return nil
    }

    /// Whether what failed was reaching the server, rather than reading it.
    private var serverUnreachable: Bool {
        app.connection.isFailed
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image("PleviLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 88, height: 88)
                .opacity(pulse ? 1 : 0.55)
                .animation(
                    .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                    value: pulse
                )
                .accessibilityHidden(true)
                .padding(.bottom, 28)

            if let failure {
                failed(failure)
            } else if finishedEmpty {
                emptyLibrary
            } else {
                stages
            }

            Spacer(minLength: 0)

            if failure == nil, !finishedEmpty {
                Button("Skip for now", action: onSkip)
                    .font(.footnote)
                    .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .onAppear { pulse = true }
        // Unstructured on purpose: the retry flips the connection to "connecting", which changes
        // this task's id and cancels it, and a `connectActive()` awaited inside a cancelled task
        // would fail its own test with the cancellation.
        .task(id: app.connection.isFailed) {
            guard app.connection.isFailed, !app.isRecovering,
                  quietRetries < Self.quietRetryLimit else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, app.connection.isFailed else { return }
            quietRetries += 1
            Task { await app.connectActive() }
        }
    }

    /// A sync has run to its end and found nothing. Without this the screen
    /// went on listing stages, with "Reaching your server" spinning, for a
    /// library that simply has no music in it.
    private var finishedEmpty: Bool {
        if case .synced = app.syncState { return app.libraryIsEmpty == true }
        return false
    }

    private var emptyLibrary: some View {
        VStack(spacing: 12) {
            Text("This library is empty")
                .font(.headline)
            Text("The server answered, but it has no music in this library yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Sync Again") { app.startBackgroundSync(force: true) }
                    .buttonStyle(.borderedProminent)
                Button("Continue", action: onSkip)
            }
            .padding(.top, 4)
        }
    }

    private var stages: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setting up your library")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)

            ForEach(Stage.allCases) { each in
                row(for: each)
            }
        }
        .frame(maxWidth: 280)
        .animation(.easeInOut(duration: 0.25), value: stage)
    }

    private func row(for each: Stage) -> some View {
        let done = each.rawValue < stage.rawValue
        let active = each == stage
        return HStack(spacing: 12) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                } else if active {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.quaternary)
                }
            }
            .frame(width: 22)

            Text(each.title)
                .font(.subheadline)
                .foregroundStyle(active ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))

            Spacer(minLength: 4)

            // The engine counts as it goes, so this is what it has actually
            // written down, not an estimate.
            if let count = count(for: each) {
                Text(count.formatted())
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .opacity(done || active ? 1 : 0.45)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 12) {
            Text(serverUnreachable ? "Couldn't reach your server" : "Couldn't load your library")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Try Again") {
                    if serverUnreachable {
                        Task { await app.connectActive() }
                    } else {
                        app.startBackgroundSync(force: true)
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Continue", action: onSkip)
            }
            .padding(.top, 4)
        }
    }
}
