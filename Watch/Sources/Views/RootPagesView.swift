import SwiftUI

/// The four pages, side by side.
struct RootPagesView: View {
    @Environment(WatchModel.self) private var model
    @State private var page: Page = .library
    @State private var hasChosenFirstPage = false

    enum Page: Hashable {
        case nowPlaying
        case library
        case downloads
        case settings
    }

    var body: some View {
        Group {
            switch model.stage {
            case .waitingForPhone:
                waiting(
                    WaitingView(
                        title: "Waiting for your iPhone",
                        detail: "Open Plevi on your iPhone once. Your server, sign-in and library arrive on their own."
                    )
                )
            case .waitingForLibrary:
                waiting(
                    WaitingView(
                        title: "Getting your library",
                        detail: model.serverName.map { "Copying \($0) across. This happens once, and it can take a few minutes." }
                            ?? "Copying your library across. This happens once."
                    )
                )
            case .ready:
                pages
            }
        }
        // The setting is read once, when the app opens, rather than watched:
        // changing it while looking at it should not throw you off the page
        // you are on.
        .task {
            guard !hasChosenFirstPage else { return }
            hasChosenFirstPage = true
            page = model.settings.startPage == .downloads ? .downloads : .library
        }
    }

    /// The waiting screen, without taking the rest of the app away.
    private func waiting(_ view: WaitingView) -> some View {
        TabView {
            view
            if model.player.currentTrack != nil {
                NowPlayingPage(isActive: false)
            }
            NavigationStack { SettingsPage() }
        }
        .tabViewStyle(.page)
    }

    /// Library, what is playing, Downloads, Settings.
    private var pages: some View {
        TabView(selection: $page) {
            NavigationStack { LibraryPage(downloadedOnly: false) }
                .tag(Page.library)
            NowPlayingPage(isActive: page == .nowPlaying)
                .tag(Page.nowPlaying)
            NavigationStack { LibraryPage(downloadedOnly: true) }
                .tag(Page.downloads)
            NavigationStack { SettingsPage() }
                .tag(Page.settings)
        }
        // Horizontal, with the system's dots at the foot. Not `.verticalPage`,
        // which hands the crown to paging — the crown belongs to volume.
        .tabViewStyle(.page)
        .onChange(of: model.wantsNowPlaying) { _, wants in
            guard wants else { return }
            model.wantsNowPlaying = false
            withAnimation { page = .nowPlaying }
        }
        // Raised here rather than on the sheet that asked, because that sheet
        // has already closed itself by the time the answer comes back.
        .alert(
            "Nothing downloaded",
            isPresented: Binding(
                get: { model.downloadProblem != nil },
                set: { if !$0 { model.clearDownloadProblem() } }
            )
        ) {
            Button("OK", role: .cancel) { model.clearDownloadProblem() }
        } message: {
            if let problem = model.downloadProblem { Text(problem) }
        }
    }
}

/// The only screen before there is a library to show.
struct WaitingView: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .padding(.bottom, 2)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    // A 42mm watch cut this off mid-sentence — "your server,
                    // your si…" — which on the one screen that explains what
                    // to do next is the half that says it.
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 8)
    }
}
