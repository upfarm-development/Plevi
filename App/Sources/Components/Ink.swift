import SwiftUI

/// The colour ordinary text is drawn in.
extension Color {
    static let ink = Color(uiColor: .ink)
}

extension UIColor {
    static let ink = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? .label
            : UIColor(red: 0.16, green: 0.17, blue: 0.19, alpha: 1)
    }
}

/// A row whose icon keeps the accent colour while its title takes the ink.
struct AccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon
                .foregroundStyle(.tint)
        }
    }
}

extension LabelStyle where Self == AccentIconLabelStyle {
    static var accentIcon: AccentIconLabelStyle { AccentIconLabelStyle() }
}
