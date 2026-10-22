import SwiftUI

@main
struct PleviWatchApp: App {
    /// One model for the life of the app, as on the phone.
    @State private var model = WatchModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootPagesView()
                .environment(model)
                .task { model.boot() }
                // Back on the wrist after the app was lowered: the network
                // may be a different one. See `WatchModel.appBecameActive`.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.appBecameActive() }
                }
        }
        // watchOS relaunches the app to finish a background transfer and hands it back this way
        // rather than through an app delegate.
        .backgroundTask(.urlSession) { identifier in
            await WatchModel.shared.finishBackgroundTransfers(identifier: identifier)
        }
    }
}
