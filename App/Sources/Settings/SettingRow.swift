import SwiftUI

/// One setting: what it is called, the control, and a line saying what it does.
struct SettingRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            control
            if let caption {
                // `LocalizedStringKey`, because `Text` parses markdown from
                // literals only — given a `String` it prints the asterisks.
                Text(LocalizedStringKey(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A control that carries its own label — a toggle, a link, a picker — with its explanation in the
/// same row.
struct SettingItem<Control: View>: View {
    var caption: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let caption {
                Text(LocalizedStringKey(caption))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A caption on its own, for the few places where it explains a whole section
/// rather than one control.
struct SettingCaption: View {
    let text: String

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            // Sits against the control it explains rather than floating in a
            // row of its own: no separator above it, and only enough room
            // below to keep it off the next setting.
            .listRowSeparator(.hidden, edges: .top)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 9, trailing: 16))
    }
}

/// A toggle whose whole row answers the tap.
struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                // The switch is a picture of the state; the row is the
                // control. Two tap targets in one row is how a tap lands
                // on neither.
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { isOn.toggle() }
    }
}
