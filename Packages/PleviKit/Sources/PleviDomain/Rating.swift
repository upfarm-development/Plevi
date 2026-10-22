import Foundation

/// A star rating in half-star steps from 0.5 to 5.0.
public struct StarRating: Hashable, Sendable, Codable {
    /// Star value in 0.5 steps within 0.5...5.0.
    public let value: Double

    public init?(_ value: Double) {
        guard (0.5...5.0).contains(value),
              (value * 2).truncatingRemainder(dividingBy: 1) == 0
        else { return nil }
        self.value = value
    }

    /// Whole-star convenience, 1...5.
    public init?(stars: Int) {
        self.init(Double(stars))
    }

    /// The nearest whole-star value 1...5, for backends without half stars.
    public var wholeStars: Int {
        Int(value.rounded())
    }
}
