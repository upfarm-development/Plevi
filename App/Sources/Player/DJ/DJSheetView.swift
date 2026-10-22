import SwiftUI
import UIKit
import PleviDomain

/// The sheet the DJ glyph opens — the "Quiet List" hand-off design: one column, full descriptions,
/// colour reduced to a dot on each row's icon tile.
struct DJSheetView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The screen behind this sheet's own palette, so the wash here echoes
    /// whatever is playing rather than always falling back to the hand-off
    /// design's default amber. Nil only where no track has ever set one.
    var palette: PlayerPalette?
    @State private var showingJourneyStep = false

    private static let cream = Color(red: 0.965, green: 0.937, blue: 0.894) // #f6efe4
    private static let darkText = Color(red: 0.110, green: 0.078, blue: 0.063) // #1c1410

    var body: some View {
        ZStack {
            background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.top, 22)
                titleBlock
                if let message = app.dj?.activationMessage {
                    banner(message) { app.dj?.dismissActivationMessage() }
                        .padding(.bottom, 12)
                }
                if let message = app.dj?.poolExhaustedMessage {
                    banner(message) { app.dj?.dismissPoolExhaustedMessage() }
                        .padding(.bottom, 12)
                }
                card
                if app.dj?.isDegraded == true {
                    Text("Some picks are using genre and era instead of sound matching right now.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Self.cream.opacity(0.42))
                        .multilineTextAlignment(.center)
                        .padding(.top, 14)
                        .padding(.horizontal, 24)
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $showingJourneyStep) {
            JourneyDestinationView { destination, length in
                if !app.remote.isControlling { app.dj?.activateJourney(destination: destination, length: length) }
                showingJourneyStep = false
                dismiss()
            }
        }
    }

    // MARK: Background

    private var background: some View {
        LinearGradient(colors: backgroundColors, startPoint: .top, endPoint: .bottom)
    }

    private var backgroundColors: [Color] {
        guard let ground = palette?.ground else { return DJStrategyCatalog.fallbackBackground }
        return [shaded(ground, by: 0.08), shaded(ground, by: -0.08), shaded(ground, by: -0.22)]
    }

    private func shaded(_ color: Color, by delta: CGFloat) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(1, s), brightness: max(0, min(1, b + delta)))
    }

    // MARK: Header

    private var header: some View {
        ZStack {
            Capsule().fill(Self.cream.opacity(0.35)).frame(width: 36, height: 5)
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Off") { app.dj?.deactivate() }
            }
            .font(.system(size: 17))
            .foregroundStyle(Self.cream)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DJ")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Self.cream)
            Text("How the next songs get chosen after the queue runs out.")
                .font(.system(size: 14.5))
                .foregroundStyle(Self.cream.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    // MARK: Card

    private var card: some View {
        VStack(spacing: 0) {
            ForEach(Array(DJStrategyCatalog.all.enumerated()), id: \.element) { index, kind in
                row(kind, showsDivider: index > 0)
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func row(_ kind: DJStrategyKind, showsDivider: Bool) -> some View {
        let isSelected = app.dj?.active == kind
        let accent = DJStrategyCatalog.tint(for: kind)
        let isArrived = kind == .journey && isSelected && app.dj?.hasArrivedAtJourneyDestination == true

        return Button {
            tap(kind, isSelected: isSelected)
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? accent : accent.opacity(0.24))
                    DJGlyph.path(for: kind)
                        .stroke(isSelected ? .white : accent, style: StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
                        .frame(width: 17, height: 17)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isArrived ? "Journey · arrived" : kind.label)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(isSelected ? Self.darkText : Self.cream)
                    Text(kind.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Self.darkText.opacity(0.65) : Self.cream.opacity(0.55))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    ZStack {
                        Circle().fill(Self.darkText)
                        DJCheckGlyph()
                            .stroke(Self.cream, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .frame(width: 9, height: 9)
                    }
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Self.cream : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if showsDivider {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Tapping an unselected row switches to it — Journey detours through its own destination step
    /// first.
    private func tap(_ kind: DJStrategyKind, isSelected: Bool) {
        if isSelected {
            app.dj?.deactivate()
            return
        }
        if kind == .journey {
            showingJourneyStep = true
        } else {
            if !app.remote.isControlling { app.dj?.activate(kind) }
            dismiss()
        }
    }

    // MARK: Banners

    private func banner(_ message: String, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Self.cream.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.cream.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
