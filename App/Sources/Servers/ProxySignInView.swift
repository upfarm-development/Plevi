import SwiftUI
@preconcurrency import WebKit
import PleviDomain
import PleviTransport
import PleviSubsonicProvider

/// Signs in to an SSO proxy standing in front of a server — Pangolin, Authelia, and the like — by
/// showing its own login page and keeping the session it hands back.
struct ProxySignInView: View {
    let config: ServerConfig
    let url: URL
    /// Called with the captured session once the API answers through it.
    let onSignedIn: (ProxySession) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: Status = .signingIn
    @State private var cookieCheck: Task<Void, Never>?

    private enum Status: Equatable {
        case signingIn
        case verifying
        case failed(String)
    }

    private var origin: URLOrigin? { URLOrigin(url: url) }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ProxyWebView(
                    url: url,
                    pins: config.pinnedCertificates,
                    onNavigated: { store in
                        scheduleCookieCheck(store)
                    }
                )
                statusBar
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cookieCheck?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { cookieCheck?.cancel() }
    }

    @ViewBuilder
    private var statusBar: some View {
        switch status {
        case .signingIn:
            banner {
                Text("Sign in to \(origin?.host ?? "the proxy") to let Plevi through.")
            }
        case .verifying:
            banner {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking access…")
                }
            }
        case .failed(let message):
            banner {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    private func banner<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.thinMaterial)
    }

    /// Re-checks after each navigation, debounced: a login flow redirects
    /// several times, and only the last one carries the session.
    private func scheduleCookieCheck(_ store: WKHTTPCookieStore) {
        cookieCheck?.cancel()
        cookieCheck = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await verify(store)
        }
    }

    private func verify(_ store: WKHTTPCookieStore) async {
        guard let origin else { return }
        let harvested = await store.allCookies().filter { cookie in
            Self.cookie(cookie, belongsTo: origin)
        }
        guard !harvested.isEmpty else { return }

        let session = ProxySession(
            origin: origin,
            cookies: harvested.map { .init(name: $0.name, value: $0.value) },
            expiresAt: harvested.compactMap(\.expiresDate).min()
        )

        status = .verifying
        // The proof that sign-in worked is the music server answering, not
        // the proxy redirecting somewhere that looks right.
        let holder = ProxySessionHolder(session)
        let probe = SubsonicProvider(
            config: config,
            credentials: .apiKey(""),
            transport: ServerHTTPTransport(config: config, timeout: 12, proxySessions: holder)
        )
        // The server's own base URL for this origin — not `url`, which is the
        // API path whose rejection raised this sheet. Handing that to the
        // client would have it build `/rest/ping.view/rest/ping.view`.
        await probe.setBaseURL(baseURL(for: origin))
        do {
            _ = try await probe.testConnection()
        } catch ProviderError.proxySignInRequired {
            // Still behind the wall — the user has more of the flow to do.
            status = .signingIn
            return
        } catch {
            // Anything else means we are through the proxy and talking to the
            // server itself; whatever it said about credentials is the setup
            // screen's business, not this sheet's. The session is good.
        }
        onSignedIn(session)
        dismiss()
    }

    /// Whichever of the server's configured addresses lives at this origin.
    private func baseURL(for origin: URLOrigin) -> URL {
        let candidates = [config.addresses.local, config.addresses.remote].compactMap(\.self)
        return candidates.first { origin.matches($0) } ?? config.addresses.preferred
    }

    /// Cookie host matching, deliberately narrow: an exact host, or a domain
    /// cookie whose parent domain the host actually sits under. Never a
    /// suffix match, which would accept `evil-example.com` for `example.com`.
    static func cookie(_ cookie: HTTPCookie, belongsTo origin: URLOrigin) -> Bool {
        let host = origin.host.lowercased()
        var domain = cookie.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        if domain == host { return true }
        return host.hasSuffix("." + domain)
    }
}

/// `WKWebView` with the app's certificate pinning applied to its challenges,
/// reporting each finished navigation so the sheet can look for a session.
private struct ProxyWebView: UIViewRepresentable {
    let url: URL
    let pins: [PinnedCertificate]
    let onNavigated: (WKHTTPCookieStore) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(pins: pins, onNavigated: onNavigated)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing survives this sheet except what we hand to the Keychain.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let pins: [PinnedCertificate]
        private let onNavigated: (WKHTTPCookieStore) -> Void

        init(pins: [PinnedCertificate], onNavigated: @escaping (WKHTTPCookieStore) -> Void) {
            self.pins = pins
            self.onNavigated = onNavigated
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onNavigated(webView.configuration.websiteDataStore.httpCookieStore)
        }

        /// The same pin check the transport makes. Without this a pinned
        /// self-signed server would fail to load its own login page, and the
        /// only way to make it load would be to trust anything.
        func webView(
            _ webView: WKWebView,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let host = challenge.protectionSpace.host.lowercased()
            let pin = pins.first { $0.origin.host == host }?.sha256
            switch ServerTrustEvaluator.evaluate(trust, pin: pin) {
            case .accept:
                completionHandler(.useCredential, URLCredential(trust: trust))
            case .reject:
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
