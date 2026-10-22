import Foundation

/// What a download queue needs from the thing that does the transferring.
public protocol BackgroundDownloading: AnyObject, Sendable {
    /// The events from here on, for one reader at a time. See
    /// `BackgroundDownloader.attach()`.
    func attach() -> AsyncStream<BackgroundDownloadEvent>

    func enqueue(id: String, request: URLRequest, to destination: URL, allowsCellular: Bool)
    func cancel(id: String)
    func cancel(ids: Set<String>)
    func cancelAll()
    func reissue(ids: Set<String>, allowsCellular: Bool) async -> Set<String>

    /// What the system is still working on.
    func running() async -> [String]

    /// Holds every running transfer, or lets them go again. See
    /// `BackgroundDownloader.setPaused(_:)`.
    func setPaused(_ paused: Bool)
}

extension BackgroundDownloading {
    /// A conformance with nothing to hold, such as a test double.
    public func setPaused(_ paused: Bool) {}
}

extension BackgroundDownloader: BackgroundDownloading {}
