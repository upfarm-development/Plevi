import Foundation
import PleviDomain

/// Local-index candidate pools for the DJ system's continuation and weaving strategies — Era,
/// Purist, Deep Cuts, Gold, Fresh.
extension LibraryIndex {
    /// Drawn to leave room for the exclusion filter to remove some and the caller still get enough.
    private static let djOverdrawFactor = 4

    private static func draw<T>(
        _ fetch: () throws -> [T], id: (T) -> MediaID, excluding: Set<MediaID>, limit: Int
    ) rethrows -> [T] {
        let rows = try fetch()
        var out: [T] = []
        out.reserveCapacity(min(limit, rows.count))
        for row in rows where !excluding.contains(id(row)) {
            out.append(row)
            if out.count == limit { break }
        }
        return out
    }

    /// DJ Era's continuation pool: everything in the given decade, resolved the same era-aware way
    /// `stationTracks(.decades(_:))` already resolves it — compilation-safe, low-confidence rows
    /// dropped rather than guessed at.
    public func djEraCandidates(
        decade: Int, excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        try Self.draw(
            { try stationTracks(.decades([decade]), limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly) },
            id: \.id, excluding: excluding, limit: limit
        )
    }

    /// DJ Purist's continuation pool: everything sharing the anchor's genre family.
    public func djGenreCandidates(
        matchingAnyOf genres: [String], excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        guard !genres.isEmpty else { return [] }
        return try Self.draw(
            { try stationTracks(.genres(genres), limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly) },
            id: \.id, excluding: excluding, limit: limit
        )
    }

    /// DJ Deep Cuts' pool: `stationTracks(.deepCuts(playsAtMost:))` already is this — a threshold
    /// parameter rather than a new query, since the station case already exists for exactly this
    /// purpose (the app's own Deep Cuts radio uses the same case…
    public func djDeepCutsCandidates(
        playsAtMost: Int, excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        try Self.draw(
            {
                try stationTracks(
                    .deepCuts(playsAtMost: playsAtMost), limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly
                )
            },
            id: \.id, excluding: excluding, limit: limit
        )
    }

    /// DJ Gold's pool: explicitly rated at or above its own threshold — 4.0 by default, stricter
    /// than `.highlyRated`'s 3.0, so this does not reuse that station case.
    public func djGoldCandidates(
        atLeast threshold: Double, excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        let filter = LibraryFilter(
            subject: .songs,
            root: FilterGroup(children: [
                .rule(FilterRule(field: .rating, op: .atLeast, value: .number(threshold))),
            ])
        )
        return try Self.draw(
            {
                try tracks(
                    matching: filter, limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly,
                    randomOrder: true
                ).filter { DJRatingFloor.requiresRating($0, atLeast: threshold) }
            },
            id: \.id, excluding: excluding, limit: limit
        )
    }

    /// DJ Fresh's pool: songs on an album added within the window, via the same
    /// `LibraryFilter`/`.dateAdded`/`.inTheLast` machinery the filter editor already offers — songs
    /// have no added-date of their own, only their album does, which is what…
    public func djFreshCandidates(
        addedWithinDays: Int, excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        let filter = LibraryFilter(
            subject: .songs,
            root: FilterGroup(children: [
                .rule(FilterRule(field: .dateAdded, op: .inTheLast, value: .days(addedWithinDays))),
            ])
        )
        return try Self.draw(
            {
                try tracks(
                    matching: filter, limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly,
                    randomOrder: true
                ).filter { DJRatingFloor.passes($0, atLeast: Self.favoriteRatingThreshold) }
            },
            id: \.id, excluding: excluding, limit: limit
        )
    }

    /// The fallback pool for Drift and Journey when a live similarity lookup has run out of
    /// neighbours and genre/era scoring has to stand in: the whole library, for
    /// `DJSimilarityScore.rank` to sort afterward — never offered unordered, since "the…
    public func djFallbackPool(
        excluding: Set<MediaID>, limit: Int, downloadedOnly: Bool = false
    ) throws -> [Track] {
        try Self.draw(
            { try stationTracks(.everything, limit: limit * Self.djOverdrawFactor, downloadedOnly: downloadedOnly) },
            id: \.id, excluding: excluding, limit: limit
        )
    }
}
