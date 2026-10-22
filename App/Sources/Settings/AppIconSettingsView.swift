import SwiftUI
import UIKit

/// One icon someone can put on their home screen.
struct AppIconChoice: Identifiable, Hashable {
    /// The name iOS knows it by, or nil for the one the app ships wearing.
    let alternateName: String?
    /// The colourway, as the artwork was named: Ember, Forest, Sky…
    let variant: String
    /// Both faces, for the picker.
    let previewLight: String
    let previewDark: String

    var id: String { alternateName ?? "default" }
}

/// A family of icons — one drawing, several colourways.
struct AppIconSet: Identifiable {
    let id: String
    let name: String
    let choices: [AppIconChoice]
}

enum AppIcons {
    static let sets: [AppIconSet] = [
        AppIconSet(id: "play", name: "Play Bird", choices: variants(family: "play")),
    ]

    /// Named as the artwork was, ordered the way the five were designed to
    /// be read as a set rather than by name.
    private static let colours = [
        "cherry cream", "golden hour", "lilac", "ocean", "sage",
    ]

    /// The icon the app ships wearing, which has no alternate name because it
    /// is the primary one in the asset catalogue.
    static let defaultVariant = (family: "play", variant: "golden hour")

    /// What the record holds once the default has been chosen on purpose, as against nothing having
    /// been chosen yet.
    static let defaultRecord = "default"

    /// Every alternate this build actually ships. A colourway can be retired
    /// in a redraw, and something has to be able to tell that a name kept
    /// from before it was is no longer one of them.
    static var alternateNames: Set<String> {
        Set(sets.flatMap(\.choices).compactMap(\.alternateName))
    }

    private static func variants(family: String) -> [AppIconChoice] {
        colours.map { colour in
            let isDefault = family == defaultVariant.family && colour == defaultVariant.variant
            let slug = colour.replacingOccurrences(of: " ", with: "-")
            return AppIconChoice(
                alternateName: isDefault ? nil : "AppIcon-\(family)-\(slug)",
                variant: colour.capitalized,
                previewLight: "IconPreview-\(family)-\(slug)-light",
                previewDark: "IconPreview-\(family)-\(slug)-dark"
            )
        }
    }
}

/// Choosing the icon on the home screen.
struct AppIconSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var failure: String?

    /// Two across. Each cell holds a pair, and a pair needs room to read as
    /// two icons rather than as one with a shadow.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 2)

    var body: some View {
        List {
            ForEach(AppIcons.sets) { set in
                Section(set.name) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(set.choices) { choice in
                            button(for: choice)
                        }
                    }
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            if let failure {
                Section {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("App Icon")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // A colourway this build no longer ships, retired in a redraw.
            if let stored = app.settings.selectedAppIconName,
               stored != AppIcons.defaultRecord,
               !AppIcons.alternateNames.contains(stored) {
                app.settings.selectedAppIconName = nil
            }
        }
    }

    /// Which icon the screen marks, worked out each time it is drawn rather than copied into view
    /// state when it appears.
    private var current: String? {
        if let stored = app.settings.selectedAppIconName {
            if stored == AppIcons.defaultRecord { return nil }
            if AppIcons.alternateNames.contains(stored) { return stored }
        }
        if app.settings.selectedAppIconName == nil, let onDevice = UIApplication.shared.alternateIconName,
           AppIcons.alternateNames.contains(onDevice) {
            return onDevice
        }
        return nil
    }

    private func button(for choice: AppIconChoice) -> some View {
        Button {
            select(choice)
        } label: {
            VStack(spacing: 6) {
                pair(choice, isCurrent: isCurrent(choice))
                Text(choice.variant)
                    .font(.caption)
                    .foregroundStyle(isCurrent(choice) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.variant) icon, light and dark")
        .accessibilityAddTraits(isCurrent(choice) ? [.isSelected] : [])
    }

    /// The light face in front, the dark one behind and to the right.
    private func pair(_ choice: AppIconChoice, isCurrent: Bool) -> some View {
        Color.clear
            .aspectRatio(1.72, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let front = proxy.size.height
                    let back = front * 0.92

                    ZStack(alignment: .topLeading) {
                        Image(choice.previewDark)
                            .resizable()
                            .frame(width: back, height: back)
                            .clipShape(.rect(cornerRadius: back * 0.22))
                            .overlay {
                                RoundedRectangle(cornerRadius: back * 0.22)
                                    .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
                            }
                            .offset(x: front * 0.80, y: front * 0.05)

                        Image(choice.previewLight)
                            .resizable()
                            .frame(width: front, height: front)
                            .clipShape(.rect(cornerRadius: front * 0.22))
                            .overlay {
                                RoundedRectangle(cornerRadius: front * 0.22)
                                    .strokeBorder(.black.opacity(0.10), lineWidth: 0.5)
                            }
                            .shadow(color: .black.opacity(0.16), radius: 3, x: -1, y: 1)
                    }
                    // Sized to the whole cell so the ring goes round the pair
                    // rather than around one of them.
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    .overlay {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: front * 0.30)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                                .padding(-5)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isCurrent {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, Color.accentColor)
                                .offset(x: 3, y: 3)
                        }
                    }
                }
            }
    }

    private func isCurrent(_ choice: AppIconChoice) -> Bool {
        current == choice.alternateName
    }

    private func select(_ choice: AppIconChoice) {
        guard current != choice.alternateName else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            failure = "This device won't let apps change their icon."
            return
        }
        UIApplication.shared.setAlternateIconName(choice.alternateName) { error in
            Task { @MainActor in
                if let error {
                    failure = "Couldn't change the icon: \(error.localizedDescription)"
                } else {
                    failure = nil
                    // What was just asked for, not a fresh read of
                    // `UIApplication.shared.alternateIconName` — the completion already says the
                    // request succeeded, and that property is the one that does not reliably agree
                    // with it.
                    app.settings.selectedAppIconName = choice.alternateName ?? AppIcons.defaultRecord
                }
            }
        }
    }
}
