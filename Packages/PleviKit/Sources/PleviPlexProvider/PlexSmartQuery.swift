import Foundation
import PleviDomain

/// A saved search written the way Plex writes one.
enum PlexSmartQuery {
    /// Plex's own numbering for the kinds of thing in a music library.
    static func type(for subject: SmartQuery.Subject) -> Int {
        switch subject {
        case .songs: 10
        case .albums: 9
        }
    }

    /// The field names Plex knows, per kind.
    static func name(for field: SmartRule.Field, subject: SmartQuery.Subject) -> String? {
        switch (field, subject) {
        case (.title, _): "title"
        case (.artistName, _): "artist.title"
        case (.albumName, .songs): "album.title"
        case (.albumName, .albums): nil
        case (.genre, _): "genre"
        case (.year, _): "year"
        case (.rating, _): "userRating"
        case (.playCount, _): "viewCount"
        case (.dateAdded, _): "addedAt"
        case (.lastPlayed, _): "lastViewedAt"
        }
    }

    /// The operator, spelled the way Plex spells it.
    static func suffix(for comparison: SmartRule.Comparison) -> String {
        switch comparison {
        case .isExactly: "="
        case .isNot: "!="
        case .contains: "="
        case .doesNotContain: "!="
        case .atLeast: ">>="
        case .atMost: "<<="
        case .greaterThan: ">>"
        case .lessThan: "<<"
        // Plex counts backwards from now with a negative period, so "in the
        // last thirty days" is "added at or after minus thirty days".
        case .inTheLastDays: ">>="
        case .notInTheLastDays: "<<"
        }
    }

    static func value(for rule: SmartRule) -> String {
        switch rule.value {
        case .text(let text): text
        // Plex keeps ratings out of ten; the app counts in stars out of five.
        case .stars(let stars): String(Int((stars * 2).rounded()))
        case .number(let number):
            number == number.rounded() ? String(Int(number)) : String(number)
        case .days(let days): "-\(days)d"
        }
    }

    /// The query a Plex section is asked with, or nil if any rule cannot be
    /// written — a partly-translated filter would silently mean something
    /// other than what it says.
    static func queryItems(for query: SmartQuery) -> [URLQueryItem]? {
        var items = [URLQueryItem(name: "type", value: String(type(for: query.subject)))]
        for (position, rule) in query.rules.enumerated() {
            guard let field = name(for: rule.field, subject: query.subject) else { return nil }
            // "Any of these" is written as an `or` joining each rule after
            // the first; "all of these" is the default and needs nothing.
            if !query.matchesAll, position > 0 {
                items.append(URLQueryItem(name: "or", value: "1"))
            }
            items.append(URLQueryItem(
                name: field + suffix(for: rule.comparison),
                value: value(for: rule)
            ))
        }
        return items
    }
}

extension MediaCollection.Kind {
    /// Plex names the kind in a collection's `subtype`.
    init?(plexSubtype: String?) {
        switch plexSubtype {
        case "album": self = .albums
        case "artist": self = .artists
        default: return nil
        }
    }
}
