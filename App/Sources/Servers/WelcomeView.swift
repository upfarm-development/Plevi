import SwiftUI

/// The first screen, before any server is known: which kind of server is
/// this? Going straight into the Navidrome form hid the fact that Plex is
/// supported at all.
struct WelcomeView: View {
    /// Plex's own colour. The two servers are equals here — one is not the
    /// real choice with the other as a consolation — so each gets a full
    /// button, in its own livery.
    private static let plexGold = Color(red: 0.898, green: 0.627, blue: 0.051)

    @State private var addingSubsonic = false
    @State private var addingPlex = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                // The mark rather than a borrowed SF Symbol: this is the first thing anyone sees of
                // the app, and a house with a note in it said nothing that the app's own face does
                // not say better.
                Image("PleviLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)

                Text("Plevi")
                    .font(.largeTitle.bold())

                // What stood here was a dictionary entry for the app's old name — the pronunciation
                // and definition of "oscine", set like a real one.
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    addingSubsonic = true
                } label: {
                    Label("Navidrome or Subsonic", systemImage: "server.rack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    addingPlex = true
                } label: {
                    Label("Plex", systemImage: "play.rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                        // Plex's gold wants dark text on it; white washes out.
                        .foregroundStyle(.black)
                }
                .buttonStyle(.borderedProminent)
                .tint(Self.plexGold)

                Text("You can add more servers later, and switch between them in Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $addingSubsonic) {
            ServerSetupView(isOnboarding: true)
        }
        .sheet(isPresented: $addingPlex) {
            PlexSetupView()
        }
    }
}
