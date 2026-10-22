import Foundation

/// Chooses which of a server's addresses to use right now.
public actor EndpointSelector {
    private let addresses: ServerAddresses
    /// What an address has to say for itself to be taken for the server.
    private let identity: EndpointIdentity
    private let session: URLSession
    private let gate = SessionGate()
    private var cached: (url: URL, at: Date)?
    private let cacheLifetime: TimeInterval = 30
    private let probeTimeout: TimeInterval

    /// How long the home address is given to answer before the remote one is used instead.
    private var patience: TimeInterval {
        #if os(watchOS)
        probeTimeout
        #else
        1
        #endif
    }

    /// Which address was last chosen and why.
    public struct Choice: Sendable, Hashable {
        public let url: URL
        /// Whether the local address answered the probe. False means the
        /// remote one is in use, either by choice or because the local one
        /// did not answer.
        public let isLocal: Bool
        /// The local address's own host, when this server has a local address configured at all —
        /// set whether or not it is the one in use, so the screen that reads this can say what was
        /// tried and not only what was picked.
        public let localHost: String?
        /// Why the local address did not answer, when it did not.
        public let localFailure: String?
        public let at: Date
    }

    public private(set) var lastChoice: Choice?

    public init(config: ServerConfig, identityProvider: any ClientIdentityProviding = NoClientIdentity()) {
        self.addresses = config.addresses
        self.identity = EndpointIdentity(config: config)
        let delegate = ServerSessionDelegate(
            pins: config.pinnedCertificates,
            allowedOrigins: config.allowedOrigins,
            identityProvider: identityProvider
        )
        let configuration = URLSessionConfiguration.ephemeral
        // An ephemeral session still keeps an in-memory cache, and a
        // cacheable answer from a minute ago is not evidence that the address
        // answers now — the one thing this session exists to find out.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Three seconds is calibrated for a phone on Wi-Fi.
        #if os(watchOS)
        let probeTimeout: TimeInterval = 10
        #else
        let probeTimeout: TimeInterval = 3
        #endif
        self.probeTimeout = probeTimeout
        configuration.timeoutIntervalForRequest = probeTimeout
        configuration.timeoutIntervalForResource = probeTimeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// The base URL requests should currently use.
    public func activeBaseURL() async -> URL {
        // With a single address there is nothing to choose, so skip the probe.
        guard let (local, remote) = addresses.probeOrder else {
            let only = addresses.preferred
            lastChoice = Choice(
                url: only, isLocal: addresses.local != nil,
                localHost: nil, localFailure: nil, at: Date()
            )
            return only
        }
        if let cached, Date().timeIntervalSince(cached.at) < cacheLifetime {
            return cached.url
        }
        // A selector that has been let go of does not probe: its session may
        // already be gone. Whoever still asks gets the address it last chose,
        // or the one that does not depend on being at home.
        guard gate.enter() else { return cached?.url ?? remote }
        defer { gate.leave(session) }
        // The probe itself is the child of this group, not something the group waits on
        // second-hand.
        enum Outcome: Sendable {
            case answered(String?)
            case outOfPatience
        }
        let patience = self.patience
        let identity = self.identity
        let outcome = await withTaskGroup(of: Outcome.self, returning: Outcome.self) { group in
            group.addTask { [session] in
                do {
                    let (data, response) = try await session.data(for: identity.probeRequest(base: local))
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    // Whatever answered has to be the server, or credentials
                    // would follow it — see `EndpointIdentity`.
                    guard identity.judge(status: status, body: data).isUsable else {
                        return .answered(EndpointSelector.notTheServer)
                    }
                    return .answered(nil)
                } catch {
                    // The short form: what the system itself calls the failure, stripped of the
                    // request that provoked it — a watch screen has no room for a URL and does not
                    // need one, only the reason.
                    return .answered((error as NSError).localizedDescription)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(patience))
                return .outOfPatience
            }
            let first = await group.next() ?? .outOfPatience
            group.cancelAll()
            return first
        }

        let chosen: URL
        let localAnswered: Bool
        var localFailure: String?
        switch outcome {
        case .answered(nil):
            chosen = local
            localAnswered = true
        case .answered(let why):
            chosen = remote
            localAnswered = false
            localFailure = why
        case .outOfPatience:
            chosen = remote
            localAnswered = false
            // Not localised, and deliberately in the same register as the
            // system's own messages, because that is what the other branch
            // puts here and the screen showing it cannot tell them apart.
            localFailure = "The home address did not answer in time."
        }
        cached = (chosen, Date())
        lastChoice = Choice(
            url: chosen, isLocal: localAnswered,
            localHost: local.host(), localFailure: localFailure, at: Date()
        )
        return chosen
    }

    /// What a home address that answered, but as something else, is reported
    /// as. In the register of the other reasons: a screen shows it as it is.
    static let notTheServer = "The home address answered, but not as this server."

    /// Call when the network path changes so the next request re-probes.
    public func invalidate() {
        cached = nil
    }

    /// Lets the probe session go once its requests have finished.
    public func close() {
        gate.close(session)
    }
}
