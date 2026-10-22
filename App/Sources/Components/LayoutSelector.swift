import SwiftUI

/// The four-way Off / Grid / Carousel / List control on the Pages settings.
struct LayoutSelector: View {
    /// Nil selects nothing, which is what "Set all" wants: it is an action,
    /// and the rows below are the state.
    let selection: SectionLayout?
    let onSelect: (SectionLayout) -> Void

    private static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SectionLayout.allCases) { layout in
                Image(systemName: layout.symbolName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(foreground(for: layout))
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.height - 4)
                    .background {
                        if selection == layout {
                            Capsule().fill(tint(for: layout))
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(layout) }
                    .accessibilityElement()
                    .accessibilityLabel(layout.label)
                    .accessibilityAddTraits(selection == layout ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .frame(height: Self.height)
        .background(Capsule().fill(Color.secondary.opacity(0.18)))
        .animation(.easeOut(duration: 0.15), value: selection)
    }

    private func tint(for layout: SectionLayout) -> Color {
        layout == .off ? .red : .accentColor
    }

    private func foreground(for layout: SectionLayout) -> Color {
        selection == layout ? .white : .secondary
    }
}
