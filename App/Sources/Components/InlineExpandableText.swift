import SwiftUI
import CoreText
import UIKit

// MARK: - What SwiftUI actually does vertically

/// The two numbers that describe how tall a run of SwiftUI body text stands: the height of one
/// line, and how much each line after it adds.
@MainActor
enum BodyTextMetrics {
    struct Metrics: Equatable {
        /// The height of a single line.
        var first: CGFloat
        /// What every line after the first adds. `n` lines stand exactly
        /// `first + (n - 1) * step` tall, at every size and line count
        /// measured.
        var step: CGFloat

        /// How many lines stand in `height`.
        func lines(fitting height: CGFloat) -> Int {
            guard step > 0, height >= first else { return height > 0 ? 1 : 0 }
            return 1 + Int(((height - first) / step).rounded(.down))
        }
    }

    /// What to measure. `.callout` is the only body face the About blocks
    /// use; a second style would mean a second case here rather than a string.
    struct Request: Hashable {
        var size: DynamicTypeSize
        var lineSpacing: CGFloat
        var font: Font { .callout }
    }

    private static var cache: [Request: Metrics] = [:]

    /// What is already known, without measuring anything.
    static func cached(_ key: Request) -> Metrics? { cache[key] }

    /// Measures and stores the metrics if they are not already known.
    @discardableResult
    static func prepare(_ key: Request) -> Metrics {
        if let known = cache[key] { return known }
        let (font, size, lineSpacing) = (key.font, key.size, key.lineSpacing)

        var scale: CGFloat = 2
        func height(_ text: String) -> CGFloat {
            let probe = Text(verbatim: text)
                .font(font)
                .lineSpacing(lineSpacing)
                .dynamicTypeSize(size)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 2000, alignment: .leading)
            let host = UIHostingController(rootView: probe)
            scale = host.traitCollection.displayScale > 0 ? host.traitCollection.displayScale : 2
            return host.sizeThatFits(in: CGSize(width: 2000, height: 100_000)).height
        }

        // "Ag" carries an ascender and a descender; the measurement is content-independent in any
        // case — emoji, CJK and accented capitals all report the same line height — but a letter
        // with both is the honest probe.
        let one = height("Ag")
        let nine = height(Array(repeating: "Ag", count: 9).joined(separator: "\n"))
        let averaged = (nine - one) / 8
        let measured = Metrics(first: one, step: max(1, (averaged * scale).rounded(.up) / scale))
        cache[key] = measured
        return measured
    }
}

// MARK: - Where to cut

/// Works out how much of a body of text will set in a given box, and where to cut it so a trailing
/// "… More" lands on the last line rather than under it.
enum FittedBodyText {

    struct Fit: Equatable {
        /// The text to set, trimmed of the trailing space a cut usually
        /// leaves behind.
        var visible: String
        /// What goes between the words and the affordance.
        var lead: String
        /// Whether anything was left out — and so whether to draw the
        /// affordance at all. A short biography gets no ellipsis and no
        /// "More": there is nothing behind it to go to.
        var isTruncated: Bool
        /// Whether the affordance actually fits at the end of the last line.
        var fitsInline = true

        static let empty = Fit(visible: "", lead: "", isTruncated: false)
        /// No cut puts the affordance on the last line at this width.
        static let needsStacking = Fit(visible: "", lead: "", isTruncated: true, fitsInline: false)
    }

    enum Metrics {
        /// Taken off the width the last line is measured against, to absorb the sub-point
        /// disagreement between Core Text's advance sums and SwiftUI's.
        static let slack: CGFloat = 2
        static let ellipsis = "… "
        static let space = " "
        /// Characters the cut may need to look at.
        static func budget(width: CGFloat, lines: Int, font: UIFont) -> Int {
            let narrowest = max(1, ("l" as NSString).size(withAttributes: [.font: font]).width)
            return Int((width / narrowest).rounded(.up)) * (lines + 2) + 64
        }
    }

    static func fit(
        _ text: String,
        width: CGFloat,
        maxLines: Int,
        font: UIFont,
        label: String,
        moreWidth: CGFloat
    ) -> Fit {
        guard width > 1, maxLines >= 1, !text.isEmpty else { return .empty }

        let budget = Metrics.budget(width: width, lines: maxLines, font: font)
        let slice = String(text.prefix(budget))
        var fit = cut(slice, width: width, maxLines: maxLines, font: font, label: label, moreWidth: moreWidth)
        if !fit.isTruncated, slice.count < text.count {
            // The budget was not generous enough — only possible with a font
            // whose narrowest glyph is not narrow. Redo it the slow way
            // rather than quietly drop the rest of the biography.
            fit = cut(text, width: width, maxLines: maxLines, font: font, label: label, moreWidth: moreWidth)
        }
        return fit
    }

    private static func cut(
        _ text: String,
        width: CGFloat,
        maxLines: Int,
        font: UIFont,
        label: String,
        moreWidth: CGFloat
    ) -> Fit {
        let attributed = NSAttributedString(string: text, attributes: attributes(font: font))
        let lines = layout(attributed, width: width, maxLines: maxLines)
        guard lines.count > maxLines else {
            return Fit(visible: text, lead: "", isTruncated: false)
        }

        // Core Text counts in UTF-16, which is why the slicing below goes
        // through `NSString` rather than `String.Index`.
        let source = attributed.string as NSString
        let room = max(0, width - moreWidth - Metrics.slack)

        // Walk back from the last line the box allows until a cut is found that survives being laid
        // out again.
        var line = maxLines
        while line >= 1 {
            if let candidate = candidate(
                endingOnLine: line,
                of: lines,
                in: attributed,
                source: source,
                width: width,
                room: room,
                font: font,
                label: label
            ) {
                return candidate
            }
            line -= 1
        }
        return .needsStacking
    }

    /// The cut that ends the text on `line`, or `nil` where that cut does not
    /// leave the affordance at the end of that line.
    private static func candidate(
        endingOnLine line: Int,
        of lines: [CTLine],
        in attributed: NSAttributedString,
        source: NSString,
        width: CGFloat,
        room: CGFloat,
        font: UIFont,
        label: String
    ) -> Fit? {
        let start = CTLineGetStringRange(lines[line - 1]).location
        guard start >= 0, start < source.length else { return nil }

        // A paragraph break ends a line however much room is left, so the tail is clipped at the
        // first newline: without that, the words of the next paragraph get measured as though they
        // belonged on this line and the cut lands far too late.
        var tailLength = source.length - start
        let hard = source.rangeOfCharacter(
            from: .newlines,
            options: [],
            range: NSRange(location: start, length: tailLength)
        )
        if hard.location != NSNotFound { tailLength = hard.location - start }
        guard tailLength > 0 else { return nil }

        let tail = attributed.attributedSubstring(from: NSRange(location: start, length: tailLength))
        let typesetter = CTTypesetterCreateWithAttributedString(tail)
        // `CTTypesetterSuggestLineBreak` never returns nothing: asked for a width narrower than the
        // first character it hands back that character anyway, so a count above zero is no promise
        // that the line fits.
        let fitted = CTTypesetterSuggestLineBreak(typesetter, 0, Double(room))
        guard fitted > 0 else { return nil }

        let end = min(start + fitted, source.length)
        let visible = trimmingTrailingWhitespace(source.substring(to: end))
        guard !visible.isEmpty else { return nil }
        let lead = lead(after: visible)

        // Lay the finished thing out and look at it. Verified rather than
        // trusted: this is the only step that can tell a cut that works from
        // one that quietly rearranges the lines above it.
        let composed = compose(visible: visible, lead: lead, label: label, font: font)
        let composedLines = layout(composed, width: width, maxLines: line)
        guard composedLines.count == line, let last = composedLines.last else { return nil }
        // The affordance has to share its line with some of the words. If the
        // last line starts at or after the end of the body text, "More" is on
        // its own down there, which is the shape this exists to avoid.
        let bodyLength = (visible as NSString).length
        guard CTLineGetStringRange(last).location < bodyLength else { return nil }

        return Fit(visible: visible, lead: lead, isTruncated: true)
    }

    /// The text as it will be set: the words, the lead, and the affordance in
    /// the heavier face.
    private static func compose(
        visible: String,
        lead: String,
        label: String,
        font: UIFont
    ) -> NSAttributedString {
        let composed = NSMutableAttributedString(
            string: visible + lead,
            attributes: attributes(font: font)
        )
        composed.append(NSAttributedString(string: label, attributes: attributes(font: font.semibold)))
        return composed
    }

    /// Lines of `attributed` at `width`, laid out in a frame only ever tall
    /// enough to answer "is there more than `maxLines`?".
    private static func layout(_ attributed: NSAttributedString, width: CGFloat, maxLines: Int) -> [CTLine] {
        guard let font = attributed.length > 0
            ? attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            : nil
        else { return [] }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let probe = CGRect(x: 0, y: 0, width: width, height: font.lineHeight * CGFloat(maxLines + 3))
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            CGPath(rect: probe, transform: nil),
            nil
        )
        return CTFrameGetLines(frame) as? [CTLine] ?? []
    }

    /// The room the affordance needs at the end of a line. Always measured
    /// with the ellipsis, which is the wider of the two leads, so a block
    /// that ends up using the plain space has room to spare rather than none.
    static func width(ofMore label: String, font: UIFont) -> CGFloat {
        let run = NSMutableAttributedString(string: Metrics.ellipsis, attributes: [.font: font])
        run.append(NSAttributedString(string: label, attributes: [.font: font.semibold]))
        return run.size().width.rounded(.up)
    }

    /// An ellipsis says a sentence was cut short.
    private static func lead(after visible: String) -> String {
        var tail = Substring(visible)
        while let last = tail.last, "\"')]}\u{2019}\u{201D}".contains(last) { tail = tail.dropLast() }
        guard let last = tail.last else { return "" }
        return ".!?\u{2026}".contains(last) ? Metrics.space : Metrics.ellipsis
    }

    private static func trimmingTrailingWhitespace(_ string: String) -> String {
        var trimmed = Substring(string)
        while let last = trimmed.last, last.isWhitespace || last.isNewline { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    private static func attributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        // Word wrapping and nothing else.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = .natural
        return [.font: font, .paragraphStyle: paragraph]
    }
}

// MARK: - Matching SwiftUI's font

extension UIContentSizeCategory {
    /// Written out rather than taken from SwiftUI's own bridge, which goes by
    /// way of the deprecated `ContentSizeCategory` and hands back an optional
    /// for something that can never be absent.
    init(dynamicTypeSize size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}

extension UIFont {
    /// The `UIFont` a SwiftUI text style resolves to *in this view*.
    static func matching(_ style: UIFont.TextStyle, size: DynamicTypeSize) -> UIFont {
        preferredFont(
            forTextStyle: style,
            compatibleWith: UITraitCollection(
                preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize: size)
            )
        )
    }

    /// The same face one weight up, for the affordance at the end of the line.
    /// A size of 0 on the descriptor keeps whatever size the text style
    /// resolved to, so this stays right at every Dynamic Type step.
    var semibold: UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold]
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

// MARK: - The view

/// Body text clamped to a *height* rather than a line count, with its "More" control set inline at
/// the end of the last line it can show.
struct InlineExpandableText: View {
    let text: String
    /// The column's width.
    let width: CGFloat
    /// What the block may occupy: on the wide header, the distance from the
    /// top of the About text down to the bottom edge of the cover.
    let availableHeight: CGFloat

    var palette: ArtworkPalette = .neutral
    /// The heading the sheet carries, so a biography and a review can say
    /// which of the two they are.
    var sheetTitle: String = "About"
    /// The same words the phone's `ExpandableText` uses.
    var moreLabel: String = "Show More"
    /// The affordance's colour.
    var moreColor: Color = .accentColor

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.lineSpacing) private var lineSpacing

    @State private var metrics: BodyTextMetrics.Metrics?
    @State private var showsSheet = false

    private var metricsKey: BodyTextMetrics.Request {
        .init(size: dynamicTypeSize, lineSpacing: lineSpacing)
    }

    var body: some View {
        Group {
            // The state first, then whatever the process already measured for
            // this text size — see `BodyTextMetrics.cached`. Only a size
            // nothing has drawn at yet reaches the empty branch.
            if let metrics = metrics ?? BodyTextMetrics.cached(metricsKey), width > 1 {
                block(metrics)
            } else {
                // One frame, before the line metrics have been measured or before the column has
                // reported its width.
                Color.clear.frame(height: availableHeight)
            }
        }
        .task(id: metricsKey) { metrics = BodyTextMetrics.prepare(metricsKey) }
        .sheet(isPresented: $showsSheet) {
            AboutSheet(title: sheetTitle, text: text, palette: palette)
        }
    }

    @ViewBuilder
    private func block(_ metrics: BodyTextMetrics.Metrics) -> some View {
        let font = UIFont.matching(.callout, size: dynamicTypeSize)
        let maxLines = metrics.lines(fitting: availableHeight)
        let fit = fit(maxLines: maxLines, font: font)

        Group {
            if fit.fitsInline {
                Text(composed(fit))
            } else {
                stacked(maxLines: maxLines)
            }
        }
        .font(.callout)
        .foregroundStyle(palette.secondaryForeground)
        .multilineTextAlignment(.leading)
        // No line limit on the inline case, deliberately.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The whole block is the control, as on the phone: a wall of text that
        // happens to be tappable is a secret, so the words say "More" and the
        // block takes the tap.
        .contentShape(Rectangle())
        .onTapGesture { if fit.isTruncated { showsSheet = true } }
        .accessibilityElement(children: .combine)
        // The whole text whenever there is no cut to read out — and also when the cut came back
        // empty, which is what `Fit.needsStacking` is: it reports `isTruncated` with nothing
        // visible, because no cut puts the affordance on the last line at that…
        .accessibilityLabel(fit.isTruncated && !fit.visible.isEmpty ? fit.visible : text)
        .accessibilityAddTraits(fit.isTruncated ? .isButton : [])
        .accessibilityHint(fit.isTruncated ? "Shows the full text" : "")
        .accessibilityAction { if fit.isTruncated { showsSheet = true } }
    }

    private func fit(maxLines: Int, font: UIFont) -> FittedBodyText.Fit {
        // Accessibility sizes never take the inline treatment.
        guard !dynamicTypeSize.isAccessibilitySize else { return .needsStacking }
        return FittedBodyText.fit(
            text,
            width: width,
            maxLines: maxLines,
            font: font,
            label: moreLabel,
            moreWidth: FittedBodyText.width(ofMore: moreLabel, font: font)
        )
    }

    private func composed(_ fit: FittedBodyText.Fit) -> AttributedString {
        var body = AttributedString(fit.visible)
        guard fit.isTruncated else { return body }
        body.append(AttributedString(fit.lead))
        var more = AttributedString(moreLabel)
        more.font = .callout.weight(.semibold)
        more.foregroundColor = moreColor
        body.append(more)
        return body
    }

    /// The phone's shape, for the cases the inline one cannot serve: the text
    /// clamped a line short, and the control on the line that frees up.
    private func stacked(maxLines: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .lineLimit(max(1, maxLines - 1))
                .truncationMode(.tail)
            Text(moreLabel)
                .fontWeight(.semibold)
                .foregroundStyle(moreColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The whole text, on a page of its own.
struct AboutSheet: View {
    let title: String
    let text: String
    var palette: ArtworkPalette = .neutral

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(palette.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .scrollBounceBehavior(.basedOnSize)
            // A sheet is presented in a host of its own and does not inherit
            // the app-wide removal from `RootView` — the same line every
            // other sheet in the app carries, for the same reason.
            .withoutBottomScrollEdgeBlur()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(palette.background)
    }
}
