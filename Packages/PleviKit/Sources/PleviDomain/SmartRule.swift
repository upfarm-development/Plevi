import Foundation

/// One rule of a saved search, in terms neither the database nor any one server owns.
public struct SmartRule: Hashable, Sendable {
    public enum Field: String, Sendable {
        case title
        case artistName
        case albumName
        case genre
        case year
        case rating
        case playCount
        case dateAdded
        case lastPlayed
    }

    /// Only the comparisons every server can be expected to have. Anything
    /// finer is a rule this cannot carry, and it says so rather than sending
    /// something that quietly means something else.
    public enum Comparison: String, Sendable {
        case isExactly
        case isNot
        case contains
        case doesNotContain
        case atLeast
        case atMost
        case greaterThan
        case lessThan
        case inTheLastDays
        case notInTheLastDays
    }

    public enum Value: Hashable, Sendable {
        case text(String)
        /// Stars, as the app counts them: 0.5 to 5.
        case stars(Double)
        case number(Double)
        case days(Int)
    }

    public var field: Field
    public var comparison: Comparison
    public var value: Value

    public init(field: Field, comparison: Comparison, value: Value) {
        self.field = field
        self.comparison = comparison
        self.value = value
    }
}

/// A saved search a server can be asked to keep for itself.
public struct SmartQuery: Hashable, Sendable {
    public enum Subject: String, Sendable {
        case songs
        case albums
    }

    public var subject: Subject
    /// Every rule has to match, or any of them.
    public var matchesAll: Bool
    public var rules: [SmartRule]

    public init(subject: Subject, matchesAll: Bool, rules: [SmartRule]) {
        self.subject = subject
        self.matchesAll = matchesAll
        self.rules = rules
    }
}
