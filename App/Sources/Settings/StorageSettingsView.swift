import SwiftUI
import PleviDomain

/// What the app keeps on the phone, and what it asks the server to send:
/// downloads, the caches behind them, and how much is converted on the way.
struct StorageSettingsView: View {
    /// Counts the kept songs at a quality the setting no longer asks for.
    private func countKeptAtOtherQuality() async {
        keptAtOtherQuality = await app.downloads?.countAtOtherQuality() ?? 0
    }

    /// How many kept songs are at a quality the setting no longer asks for.
    /// Counted when the screen opens and after a re-fetch, rather than from
    /// the body: it walks every download.
    @State private var keptAtOtherQuality = 0
    @State private var isRefetching = false

    static let prefetchChoices = [1, 3, 5, 10, 15, 20, 30]
    /// Doubling from one: a phone with room to spare can hold a library's
    /// worth, and a phone without one is not surprised.
    static let cacheChoices = [1, 2, 4, 8, 16, 32, 64]
    /// Megabytes. A grid sleeve is 30–60 KB, so 500 covers a few thousand of
    /// them with the larger detail sizes alongside.
    static let artworkCacheChoices = [100, 250, 500, 1000, 2000]

    @Environment(AppModel.self) private var app
    @State private var cacheUsage: Int64 = 0
    @State private var artworkUsage: Int64 = 0
    @State private var downloadsUsage: Int64 = 0

    private var cacheUsageText: String {
        cacheUsage > 0
            ? ByteCountFormatter.string(fromByteCount: cacheUsage, countStyle: .file)
            : "Nothing yet"
    }

    private var downloadsUsageText: String {
        downloadsUsage > 0
            ? ByteCountFormatter.string(fromByteCount: downloadsUsage, countStyle: .file)
            : "Nothing yet"
    }

    private var librarySentText: String {
        guard let date = app.watch.librarySentAt else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    private var artworkUsageText: String {
        artworkUsage > 0
            ? ByteCountFormatter.string(fromByteCount: artworkUsage, countStyle: .file)
            : "Nothing yet"
    }

    private func refreshCacheUsage() async {
        cacheUsage = await app.mediaCacheUsage()
        artworkUsage = await app.artworkCacheUsage()
        // Off the main actor like the two above it.
        downloadsUsage = await Task.detached(priority: .utility) {
            DownloadStore.usageOfEveryLibrary()
        }.value
    }

    var body: some View {
        List {
            Section("Downloads") {
                @Bindable var settings = app.settings
                SettingItem {
                    SettingToggle("Offline mode", isOn: $settings.offlineMode)
                }
                SettingItem {
                    SettingToggle("Download over mobile data", isOn: $settings.downloadsOverCellular)
                        // Saying yes here releases whatever was waiting for
                        // Wi-Fi, rather than leaving it to wait for a change
                        // of network that may never come.
                        .onChange(of: settings.downloadsOverCellular) { _, _ in
                            app.downloads?.networkPolicyChanged()
                        }
                }

                SettingItem {
                    SettingToggle("Refresh playlists at launch", isOn: $settings.refreshPlaylistsAtLaunch)
                }
                SettingItem(caption: "Keeps downloaded music's covers, names and album reviews current with your library, including reviews and covers that appeared after you downloaded it.") {
                    SettingToggle("Refresh album details at launch", isOn: $settings.refreshDownloadedDetailsAtLaunch)
                }
                SettingItem(caption: app.quickSwitchChoices.count > 1
                    ? nil
                    : "Needs more than one library ticked under Quick Switch.") {
                    SettingToggle("Merge downloads from all libraries", isOn: $settings.mergesDownloads)
                }
                LabeledContent("Space used", value: downloadsUsageText)

                if let summary = app.settings.lastBatchSummary {
                    SettingItem {
                        LabeledContent("Last batch", value: summary)
                    }
                }
                if let outbox = app.outbox, outbox.pending > 0 {
                    SettingItem {
                        LabeledContent("Changes waiting to send", value: "\(outbox.pending)")
                    }
                    Button("Send Now") {
                        Task { await outbox.drain() }
                    }
                    .disabled(app.isOffline)
                    if let failure = outbox.lastFailure {
                        SettingCaption(text: "Last attempt: \(failure)")
                    }
                }
            }

            if app.watch.isWatchAppInstalled {
                Section("Apple Watch") {
                    SettingItem {
                        LabeledContent("Library sent", value: librarySentText)
                    }
                    Button(app.watch.isSendingLibrary ? "Sending…" : "Send Now") {
                        app.watch.sendLibrary(force: true)
                    }
                    .disabled(app.watch.isSendingLibrary || !app.watch.canSendLibrary)
                    if let failure = app.watch.lastFailure {
                        SettingCaption(text: "Last attempt: \(failure)")
                    }
                }
            }

            Section("Transcoding") {
                @Bindable var settings = app.settings
                // No captions here, and one word each.
                NavigationLink {
                    TranscodeSettingsView(
                        title: "Wi-Fi",
                        policy: $settings.streamingTranscodeWiFi
                    )
                } label: {
                    LabeledContent("Wi-Fi", value: settings.streamingTranscodeWiFi.threshold.label)
                }

                NavigationLink {
                    TranscodeSettingsView(
                        title: "Cellular",
                        policy: $settings.streamingTranscodeCellular
                    )
                } label: {
                    LabeledContent("Cellular", value: settings.streamingTranscodeCellular.threshold.label)
                }

                SettingItem(caption: "Streams Wi-Fi away from your server's home network the way it streams mobile data, so the original file can stay for home. Needs a server with a home and a remote address.") {
                    Toggle("Treat other Wi-Fi as cellular", isOn: $settings.awayWiFiUsesMobilePolicy)
                }

                NavigationLink {
                    TranscodeSettingsView(
                        title: "Downloads",
                        policy: $settings.downloadTranscode
                    )
                } label: {
                    LabeledContent("Downloads", value: settings.downloadTranscode.threshold.label)
                }

                // Only where there is something to say.
                if keptAtOtherQuality > 0 {
                    SettingItem(caption: "Each is replaced only once the new copy has arrived.") {
                        Button {
                            Task {
                                isRefetching = true
                                await app.downloads?.refetchAtCurrentQuality()
                                await countKeptAtOtherQuality()
                                isRefetching = false
                            }
                        } label: {
                            LabeledContent(
                                "Fetch \(keptAtOtherQuality.counted("song")) again",
                                value: isRefetching ? "Working…" : ""
                            )
                        }
                        .disabled(isRefetching)
                    }
                }
            }

            Section("Play Cache") {
                @Bindable var settings = app.settings
                SettingItem {
                    Picker("Size", selection: $settings.mediaCacheGigabytes) {
                        ForEach(Self.cacheChoices, id: \.self) { size in
                            Text("\(size) GB").tag(size)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                SettingItem {
                    Toggle("Keep transcoded files", isOn: $settings.keepsConvertedFiles)
                }

                LabeledContent("Current cache size", value: cacheUsageText)
                Button("Clear cache", role: .destructive) {
                    Task {
                        await app.clearMediaCache()
                        await refreshCacheUsage()
                    }
                }
            }

            Section("Pre-cache") {
                @Bindable var settings = app.settings
                Picker("On Wi-Fi", selection: $settings.prefetchOnWiFi) {
                    ForEach(Self.prefetchChoices, id: \.self) { count in
                        Text(count.counted("song")).tag(count)
                    }
                }
                Picker("On cellular", selection: $settings.prefetchOnCellular) {
                    ForEach(Self.prefetchChoices, id: \.self) { count in
                        Text(count.counted("song")).tag(count)
                    }
                }
            }

            Section {
                @Bindable var settings = app.settings
                SettingItem {
                    Picker("Size", selection: $settings.artworkCacheMegabytes) {
                        ForEach(Self.artworkCacheChoices, id: \.self) { size in
                            Text(size < 1000 ? "\(size) MB" : "\(size / 1000) GB").tag(size)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
                LabeledContent("Current cache size", value: artworkUsageText)
                Button("Clear artwork cache", role: .destructive) {
                    Task {
                        await app.clearArtworkCache()
                        await refreshCacheUsage()
                    }
                }
            } header: {
                Text("Artwork Cache")
            } footer: {
                Text("Covers and colours of downloaded songs and playlists are kept separately, so they stay when the cache is cleared.")
            }
        }
        .navigationTitle("Downloads & Data")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshCacheUsage() }
        // Re-counted when the setting changes as well as when the screen
        // opens, so the offer appears the moment it becomes true rather than
        // on the next visit.
        .task(id: app.settings.downloadTranscode) { await countKeptAtOtherQuality() }
        // Applied as they change: choosing a smaller cache should tidy up
        // now, not at some later moment nobody can point to.
        .onChange(of: app.settings.keepsConvertedFiles) { _, keeps in
            guard !keeps else { return }
            Task {
                await app.dropConvertedFiles()
                await refreshCacheUsage()
            }
        }
        .onChange(of: app.settings.offlineMode) { app.offlineModeChanged() }
        .onChange(of: app.settings.artworkCacheMegabytes) {
            Task {
                await app.applyArtworkCacheLimit()
                await refreshCacheUsage()
            }
        }
        .onChange(of: app.settings.mediaCacheGigabytes) {
            Task {
                await app.applyMediaCacheLimit()
                await refreshCacheUsage()
            }
        }
    }
}
