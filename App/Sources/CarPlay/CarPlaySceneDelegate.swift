import CarPlay
import UIKit

/// The car's own scene.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var coordinator: CarPlayCoordinator?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        // CarPlay connecting ends control —
        // the car is this phone's own speakers, and the phone has left
        // the house's Wi-Fi.
        AppModel.shared.remote.disconnect(farewell: .carPlay)
        let coordinator = CarPlayCoordinator(
            interfaceController: interfaceController,
            app: .shared
        )
        self.coordinator = coordinator
        coordinator.start()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        coordinator?.stop()
        coordinator = nil
    }
}
