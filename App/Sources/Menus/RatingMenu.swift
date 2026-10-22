import SwiftUI
import PleviDomain

/// The "Rate…" submenu, with the current rating ticked.
struct RatingMenu: View {
    let title: String
    let current: StarRating?
    let allowsHalfStars: Bool
    let onSet: (StarRating?) -> Void

    var body: some View {
        Menu(title, systemImage: "star") {
            Picker(title, selection: selection) {
                ForEach(RatingMenuStep.all(halfSteps: allowsHalfStars), id: \.value) { step in
                    Text(step.label).tag(Double?.some(step.value))
                }
            }
            .pickerStyle(.inline)

            if current != nil {
                Divider()
                Button("Clear Rating", role: .destructive) { onSet(nil) }
            }
        }
    }

    private var selection: Binding<Double?> {
        Binding(
            get: { current?.value },
            set: { newValue in
                guard let newValue else { return }
                onSet(StarRating(newValue))
            }
        )
    }
}
