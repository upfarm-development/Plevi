import SwiftUI
import UIKit

/// Puts the chosen appearance on the window itself, and not only on the view tree inside it.
private struct WindowAppearance: ViewModifier {
    let theme: AppTheme

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: theme) { _, _ in apply() }
            // And to any window that turns up later.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIScene.didActivateNotification
                )
            ) { _ in apply() }
    }

    private func apply() {
        let style: UIUserInterfaceStyle =
            switch theme {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication
            else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}

extension View {
    /// See `WindowAppearance`.
    func windowAppearance(_ theme: AppTheme) -> some View {
        modifier(WindowAppearance(theme: theme))
    }
}
