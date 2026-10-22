import Foundation
import PleviDomain

/// Turning a filter into something a server can keep for itself.
extension LibraryFilter {
    public enum SmartQueryProblem: Error, Equatable, Sendable {
        case artistsNotSupported
        case noRules
        case nestedGroups
        case unsupportedField(String)
        case unsupportedTest(String)

        public var explanation: String {
            switch self {
            case .artistsNotSupported:
                "A server keeps smart playlists of songs and albums, not artists."
            case .noRules:
                "There are no rules to save."
            case .nestedGroups:
                "Groups inside groups cannot be carried across — flatten it to one list of rules."
            case .unsupportedField(let name):
                "\(name) is not something the server can filter on."
            case .unsupportedTest(let name):
                "\"\(name)\" is not a test the server has."
            }
        }
    }

    /// The same question in provider-neutral terms, or why it cannot be asked.
    public func smartQuery() -> Result<SmartQuery, SmartQueryProblem> {
        let subject: SmartQuery.Subject
        switch self.subject {
        case .songs: subject = .songs
        case .albums: subject = .albums
        case .artists: return .failure(.artistsNotSupported)
        }

        // One flat list. Nesting is where a translation starts guessing.
        for child in root.children {
            if case .group = child { return .failure(.nestedGroups) }
        }

        var rules: [SmartRule] = []
        for child in root.children {
            guard case .rule(let rule) = child else { continue }
            guard let field = Self.field(for: rule.field) else {
                return .failure(.unsupportedField(rule.field.title(for: self.subject)))
            }
            guard let comparison = Self.comparison(for: rule.op) else {
                return .failure(.unsupportedTest(rule.op.title(for: rule.field)))
            }
            // "Not played in the last N days" includes the songs that were never played (a missing
            // date), and a server's `lastViewedAt <<` cannot match an item that has no such date.
            if rule.op == .notInTheLast, rule.field == .lastPlayed {
                return .failure(.unsupportedTest(rule.op.title(for: rule.field)))
            }
            guard let value = Self.value(rule.value, field: field) else {
                return .failure(.unsupportedTest(rule.op.title(for: rule.field)))
            }
            rules.append(SmartRule(field: field, comparison: comparison, value: value))
        }

        guard !rules.isEmpty else { return .failure(.noRules) }
        return .success(SmartQuery(
            subject: subject,
            matchesAll: root.match == .all,
            rules: rules
        ))
    }

    private static func field(for field: FilterField) -> SmartRule.Field? {
        switch field {
        case .title: .title
        case .artistName: .artistName
        case .albumName: .albumName
        case .genre: .genre
        case .year: .year
        case .rating: .rating
        case .playCount: .playCount
        case .dateAdded: .dateAdded
        case .lastPlayed: .lastPlayed
        // Everything else is either ours alone (downloaded), or something the
        // server files differently enough that a guess would be wrong.
        case .duration, .codec, .favourite, .downloaded, .compilation,
             .bitRate, .fileSize, .trackCount, .recordLabel, .releaseType,
             .albumCount,
             // The newer fields are read off columns this library syncs and keeps; a server's own
             // smart-playlist language has no agreed name for most of them, and guessing at one
             // would build a playlist that quietly means something else.
             .criticRating, .albumRating, .albumYear, .albumPlayCount,
             .originalYear, .trackNumber, .discNumber, .sampleRate,
             .bitDepth, .channels, .bpm,
             // Plex has both of these in its own editor, and neither can be carried across as it
             // stands: its decade rule takes a decade from a list rather than a year, and its
             // release date wants a date format this has no agreed spelling of.
             .albumReleaseDate, .albumDecade,
             // Their records' genres run together, which is this app's own
             // reading of an artist rather than anything a server keeps.
             .artistGenre,
             // Answered here against a copy of the playlists this app keeps for the purpose.
             .playlistName:
            nil
        }
    }

    private static func comparison(for op: FilterOperator) -> SmartRule.Comparison? {
        switch op {
        case .matches, .equals: .isExactly
        case .doesNotMatch, .notEquals: .isNot
        case .contains: .contains
        case .doesNotContain: .doesNotContain
        case .atLeast: .atLeast
        case .atMost: .atMost
        case .greaterThan: .greaterThan
        case .lessThan: .lessThan
        case .after: .greaterThan
        case .before: .lessThan
        case .inTheLast: .inTheLastDays
        case .notInTheLast: .notInTheLastDays
        // "Begins with" and "ends with" have no plain equivalent, and
        // "is set" needs a value the server's syntax does not take.
        case .beginsWith, .endsWith, .isSet, .isNotSet, .isTrue, .isFalse: nil
        }
    }

    private static func value(_ value: FilterValue, field: SmartRule.Field) -> SmartRule.Value? {
        switch value {
        case .text(let text):
            return text.isEmpty ? nil : .text(text)
        case .number(let number):
            return field == .rating ? .stars(number) : .number(number)
        case .days(let days):
            return .days(days)
        case .date, .none:
            // A fixed date could be carried, but the app writes "in the last"
            // rules far more often and those travel better — a rule that
            // keeps meaning the same thing as time passes.
            return nil
        }
    }
}
