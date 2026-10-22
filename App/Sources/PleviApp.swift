import SwiftUI
import UIKit
import BackgroundTasks

@main
struct PleviApp: App {
    /// The shared model rather than one owned here: CarPlay is a scene of
    /// its own and needs the same player, provider and library — see
    /// `AppModel.shared`.
    private let model = AppModel.shared

    init() {
        // Navigation titles are drawn by UIKit, which does not see SwiftUI's foreground style —
        // without this the body of a page softens and its heading stays pure black.
        UINavigationBar.appearance().titleTextAttributes = [.foregroundColor: UIColor.ink]
        UINavigationBar.appearance().largeTitleTextAttributes = [.foregroundColor: UIColor.ink]

        // Both handlers are registered before anything is booked, and in that order on purpose:
        // booking a task nobody has registered is not an error `submit` returns but an exception
        // BackgroundTasks raises, which `try?` cannot catch and which ends…
        Self.registerWalkTask(model: model)
        Self.registerRefreshTask(model: model)
        Self.registerWatchTask(model: model)

        // The first booking.
        Self.scheduleRefresh()
        Self.scheduleWatchSend()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        // iOS finishes downloads while the app is closed and then relaunches it to say so.
        .backgroundTask(.urlSession(matching: { $0.hasPrefix(AppModel.downloadSessionPrefix) })) { identifier in
            await model.resumeBackgroundDownloads(identifier: identifier)
        }
    }

    /// The short wake, registered by hand.
    private static func registerRefreshTask(model: AppModel) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppModel.refreshTaskID, using: .main
        ) { task in
            MainActor.assumeIsolated {
                scheduleRefresh()
                let work = Task { @MainActor in
                    let changed = await model.backgroundRefreshFoundChanges()
                    if changed { scheduleWalk() }
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }

    /// The overnight job, registered by hand.
    private static func registerWalkTask(model: AppModel) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppModel.walkTaskID, using: .main
        ) { task in
            MainActor.assumeIsolated {
                let work = Task { @MainActor in
                    await model.backgroundWalk()
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }

    /// The watch's daily job, registered by hand for the same reasons as the
    /// other two. The next booking is made first, so a run that is cut short
    /// does not end the schedule.
    private static func registerWatchTask(model: AppModel) {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AppModel.watchTaskID, using: .main
        ) { task in
            MainActor.assumeIsolated {
                scheduleWatchSend()
                let work = Task { @MainActor in
                    await model.backgroundWatchSend()
                    task.setTaskCompleted(success: !Task.isCancelled)
                }
                task.expirationHandler = { work.cancel() }
            }
        }
    }

    /// Asks for the watch's next turn, about twelve hours out.
    nonisolated static func scheduleWatchSend() {
        let request = BGProcessingTaskRequest(identifier: AppModel.watchTaskID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks for the next short wake.
    nonisolated static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AppModel.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Asks for a walk, once something is known to have changed.
    nonisolated static func scheduleWalk() {
        let request = BGProcessingTaskRequest(identifier: AppModel.walkTaskID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        try? BGTaskScheduler.shared.submit(request)
    }
}
