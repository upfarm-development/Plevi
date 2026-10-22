import SwiftUI
import PleviDomain

/// A line across the top saying why the library looks smaller than it is.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var app
    /// Put away for this stretch of being offline.
    @Binding var isDismissed: Bool

    private var title: String {
        if app.isOfflineByChoice { return String(localized: "Offline — showing downloads") }
        switch app.connectionFailure {
        case .rejected, .notAuthorized:
            return String(localized: "Sign-in was rejected — showing downloads")
        case .certificate:
            return String(localized: "Certificate problem — showing downloads")
        case .proxyWall:
            return String(localized: "Sign-in page in the way — showing downloads")
        case .incompatible:
            return String(localized: "Server not recognised — showing downloads")
        case .setupIncomplete:
            return String(localized: "Server isn't set up — showing downloads")
        case .unreachable, .noNetwork, .other:
            return String(localized: "Can't reach the server — showing downloads")
        }
    }

    /// The server's own reason, for failures that are not about reaching it.
    private var reason: String? {
        guard !app.isOfflineByChoice, case .failed(let message) = app.connection,
              !app.connectionFailure.isReachabilityProblem else { return nil }
        return message
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: app.isOfflineByChoice ? "airplane" : "wifi.exclamationmark")
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let reason {
                    // What actually went wrong, where it is not simply "cannot be reached": a
                    // rejected sign-in is fixed by signing in, not by waiting, and "can't reach the
                    // server" sent people looking at their network.
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let waiting = app.outbox?.pending, waiting > 0 {
                    // Ratings and listens are not lost while the server is
                    // away, and saying so is the difference between "it kept
                    // it" and "did that even register".
                    Text("\(waiting) change\(waiting == 1 ? "" : "s") waiting to send")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if app.isOfflineByChoice {
                Button("Go Online") {
                    app.settings.offlineMode = false
                    // The forced sync waits for the connection inside this,
                    // rather than starting against the address chosen before
                    // Offline Mode went on.
                    app.offlineModeChanged(forcingSync: true)
                }
                .font(.footnote.weight(.semibold))
            } else {
                Button("Retry") {
                    Task { await app.connectActive() }
                }
                .font(.footnote.weight(.semibold))
            }
            // Put away rather than answered.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    // A whole corner to aim at rather than the glyph.
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide")
        }
        .font(.footnote)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
