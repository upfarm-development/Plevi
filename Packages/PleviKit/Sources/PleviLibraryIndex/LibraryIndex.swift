import Foundation
import GRDB
import PleviDomain
import Synchronization
import os

/// The local library index: one SQLite database per server, holding the full artist/album/track
/// catalog plus an FTS5 search table.
public final class LibraryIndex: Sendable {
    /// A pool on a real file, a queue in memory — see the initialisers.
    /// Held as the protocol so both fit, and because nothing in here needs
    /// either one's own API: it is `read` and `write` and nothing else.
    // `internal`, not `private`: the other files of this type reach these
    // directly rather than through a public passthrough for SQL that has no
    // business outside this module.
    let database: any DatabaseWriter
    let serverID: ServerID

    /// Every artist's own era, worked out once and kept for the session.
    private let artistEraCache = Mutex<[String: Int]?>(nil)
    private let artistGenreTagCache = Mutex<[String: Set<String>]?>(nil)

    /// Ratings and hearts given on this device, remembered while a sync is
    /// running so the walk cannot put the server's older answer over them.
    /// See `LocalWrites`.
    private let localWrites = Mutex(LocalWrites())

    private static let log = Logger(
        subsystem: Bundle.main.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String
            ?? Bundle.main.bundleIdentifier ?? "plevi",
        category: "era"
    )

    /// Which server this index is for. Rows store server-native id strings
    /// without it, so anything reading the tables directly needs it back to
    /// rebuild a `MediaID`.
    public var server: ServerID { serverID }

    /// A pool rather than a queue, which is to say: WAL, and readers that do not wait for the
    /// writer.
    public init(databaseURL: URL, serverID: ServerID) throws {
        self.database = try DatabasePool(path: databaseURL.path)
        self.serverID = serverID
        do {
            try Self.migrator.migrate(database)
        } catch {
            // Named so `LibraryIndexOpening` can tell a schema this build
            // cannot bring forward from a disk that was full.
            throw MigrationFailure(underlying: error)
        }
    }

    /// In-memory index for tests and previews.
    public init(inMemoryFor serverID: ServerID) throws {
        self.database = try DatabaseQueue()
        self.serverID = serverID
        try Self.migrator.migrate(database)
    }

    /// Internal rather than private so the migration tests can build a
    /// database as an older build left it and then open it with this one —
    /// see `MigrationTests`.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "artist") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sortName", .text)
                t.column("albumCount", .integer)
                t.column("artworkId", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("rating", .double)
                t.column("syncGen", .integer).notNull()
            }
            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("artistId", .text).indexed()
                t.column("artistName", .text)
                t.column("year", .integer).indexed()
                t.column("genre", .text).indexed()
                t.column("trackCount", .integer)
                t.column("duration", .double)
                t.column("artworkId", .text)
                t.column("addedAt", .datetime).indexed()
                t.column("playedAt", .datetime)
                t.column("playCount", .integer)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("rating", .double)
                t.column("syncGen", .integer).notNull()
            }
            try db.create(table: "track") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("albumId", .text).indexed()
                t.column("albumName", .text)
                t.column("artistId", .text).indexed()
                t.column("artistName", .text)
                t.column("trackNumber", .integer)
                t.column("discNumber", .integer)
                t.column("duration", .double)
                t.column("year", .integer)
                t.column("genre", .text).indexed()
                t.column("codec", .text)
                t.column("contentType", .text)
                t.column("bitRateKbps", .integer)
                t.column("sampleRate", .integer)
                t.column("bitDepth", .integer)
                t.column("channelCount", .integer)
                t.column("fileSize", .integer)
                t.column("artworkId", .text)
                t.column("rgTrackGain", .double)
                t.column("rgAlbumGain", .double)
                t.column("rgTrackPeak", .double)
                t.column("rgAlbumPeak", .double)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("rating", .double)
                t.column("playCount", .integer)
                t.column("syncGen", .integer).notNull()
            }
            try db.create(virtualTable: "search", using: FTS5()) { t in
                t.tokenizer = .unicode61()
                t.column("kind")
                t.column("itemId").notIndexed()
                t.column("content")
            }
            try db.create(table: "syncState") { t in
                t.primaryKey("id", .integer)
                t.column("generation", .integer).notNull()
                t.column("lastSyncAt", .datetime)
            }
        }
        // Never edit a migration that has shipped: databases that already ran
        // it will not re-run it, so new columns must arrive in a new one.
        migrator.registerMigration("v2-releaseTypes") { db in
            try db.alter(table: "album") { t in
                t.add(column: "releaseTypes", .text).notNull().defaults(to: "")
                t.add(column: "isCompilation", .boolean).notNull().defaults(to: false)
            }
        }
        // The original index used the unicode61 tokenizer, which only matches whole words and their
        // prefixes: searching "oldplay" could never find "Coldplay".
        migrator.registerMigration("v3-substringSearch") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS search")
            // The two columns are here rather than only in v27 because migrations have to replay
            // from nothing, and `repopulateSearch` — which this and two later migrations call —
            // writes them.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search USING fts5(
                    kind UNINDEXED, itemId UNINDEXED, name, artist,
                    tokenize = 'trigram remove_diacritics 1'
                )
                """)
            try Self.repopulateSearch(db)
        }
        // Artist pages depend on data no browse call returns (biography, similar artists, top
        // tracks), so each page visit used to wait on the network and reveal its sections one by
        // one.
        migrator.registerMigration("v4-artistInfo") { db in
            try db.create(table: "artistInfo") { t in
                t.primaryKey("artistId", .text)
                t.column("biography", .text)
                t.column("similarArtistIds", .text).notNull().defaults(to: "")
                t.column("topTrackIds", .text).notNull().defaults(to: "")
                t.column("fetchedAt", .datetime).notNull()
            }
        }

        // A NEW migration, never an edit to a shipped one: altering v1 would
        // leave every existing install with a table that does not match.
        migrator.registerMigration("v5-recordLabel") { db in
            try db.alter(table: "album") { table in
                table.add(column: "recordLabel", .text)
                table.add(column: "releaseDate", .datetime)
            }
        }

        migrator.registerMigration("v6-waveform") { db in
            try db.create(table: "waveform") { table in
                table.primaryKey("trackId", .text)
                // The bars as one byte each: ninety bytes a track, and a
                // level quantised to 1/255 is finer than a few points of
                // height can show.
                table.column("bars", .blob).notNull()
            }
        }

        // The popular-tracks query changed, so every cached artist page holds an answer to the old
        // question.
        migrator.registerMigration("v7-refreshArtistPages") { db in
            try db.execute(sql: "DELETE FROM artistInfo")
        }

        // Search now indexes a punctuation-folded copy alongside the original.
        migrator.registerMigration("v8-foldedSearch") { db in
            try Self.repopulateSearch(db)
        }

        // Stored waveforms were read from the audio as peaks. Where a server
        // has done its own loudness analysis the shape now comes from that
        // instead, and the two do not look alike — so the old ones go.
        migrator.registerMigration("v9-waveformSource") { db in
            try db.execute(sql: "DELETE FROM waveform")
        }

        // Registered after v9 and never before it: GRDB applies migrations in
        // registration order and refuses one that appears ahead of a
        // migration a database has already run.
        migrator.registerMigration("v10-waveformDetail") { db in
            // Stored at 90 points against a fixed -45 dB floor; both changed.
            try db.execute(sql: "DELETE FROM waveform")
        }

        migrator.registerMigration("v11-waveformAbsolute") { db in
            // Stored stretched to each track's own loudest point; now on one
            // absolute scale.
            try db.execute(sql: "DELETE FROM waveform")
        }

        // Downloads: what is on the phone deliberately, as opposed to what the play cache happens
        // to be holding.
        migrator.registerMigration("v12-downloads") { db in
            try db.create(table: "download") { table in
                table.primaryKey("trackId", .text)
                table.column("state", .text).notNull()
                // Within the server's own download directory.
                table.column("fileName", .text)
                table.column("bytes", .integer)
                table.column("expectedBytes", .integer)
                table.column("variant", .text).notNull().defaults(to: "orig")
                table.column("addedAt", .datetime).notNull()
                table.column("failure", .text)
                // Which album, playlist, artist or bare track asked for this, newline separated:
                // removing an album takes back only what that album brought, and leaves a song you
                // also kept on its own where it is.
                table.column("requestedBy", .text).notNull().defaults(to: "")
            }
        }

        // Changes made with no server to send them to. Ratings, hearts and
        // plays are worth keeping through a flight; they are replayed in the
        // order they happened once there is a server again.
        migrator.registerMigration("v13-outbox") { db in
            try db.create(table: "outbox") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("kind", .text).notNull()
                table.column("itemId", .text).notNull().indexed()
                table.column("mediaKind", .text)
                table.column("rating", .double)
                table.column("flag", .boolean)
                table.column("at", .datetime).notNull()
                table.column("attempts", .integer).notNull().defaults(to: 0)
                table.column("lastError", .text)
            }
        }

        // A downloaded playlist, kept whole.
        migrator.registerMigration("v14-downloadedPlaylists") { db in
            try db.create(table: "downloadedPlaylist") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                table.column("artworkId", .text)
                // Newline separated, in playing order.
                table.column("trackIds", .text).notNull().defaults(to: "")
                table.column("addedAt", .datetime).notNull()
            }
        }

        // Enough of the song to show it without the library.
        migrator.registerMigration("v15-downloadDetails") { db in
            try db.alter(table: "download") { table in
                table.add(column: "title", .text)
                table.add(column: "artistName", .text)
                table.add(column: "albumName", .text)
                table.add(column: "artworkId", .text)
                table.add(column: "duration", .double)
            }
        }

        // When a song was last heard. The servers have always sent it and we
        // have always dropped it; a shuffle that avoids what you just heard
        // cannot work without it.
        migrator.registerMigration("v16-trackPlayedAt") { db in
            try db.alter(table: "track") { t in
                t.add(column: "playedAt", .datetime)
            }
        }

        // When a downloaded playlist was last checked against the server, and whether the server
        // still has it.
        migrator.registerMigration("v17-downloadedPlaylistSync") { db in
            try db.alter(table: "downloadedPlaylist") { table in
                table.add(column: "checkedAt", .datetime)
                table.add(column: "missingFromServer", .boolean).defaults(to: false)
            }
        }

        // When the song itself says what year it was made, which is the only
        // signal a decade radio has that a compilation cannot mislead — see
        // `TrackEra`. Indexed because every decade station filters on it.
        migrator.registerMigration("v18-trackOriginalYear") { db in
            try db.alter(table: "track") { table in
                table.add(column: "originalYear", .integer)
            }
            try db.create(
                index: "track_originalYear",
                on: "track",
                columns: ["originalYear"],
                ifNotExists: true
            )
        }

        // What a reviewer made of a record, and what they wrote.
        migrator.registerMigration("v19-albumCriticRating") { db in
            try db.alter(table: "album") { table in
                table.add(column: "criticRating", .double)
                table.add(column: "review", .text)
            }
            try db.create(
                index: "album_criticRating",
                on: "album",
                columns: ["criticRating"],
                ifNotExists: true
            )
        }

        // The wider reading of "this is somebody else's records gathered up" that the era pipeline
        // needs, kept apart from the server's own `isCompilation` so that widening it does not
        // relabel records everywhere else in the app — see the note on…
        migrator.registerMigration("v20-albumIsCollection") { db in
            let existing = try db.columns(in: "album").map(\.name)
            guard !existing.contains("isCollection") else { return }
            try db.alter(table: "album") { table in
                table.add(column: "isCollection", .boolean).notNull().defaults(to: false)
            }
        }

        // The two orders the songs list is actually browsed in.
        migrator.registerMigration("v21-songBrowsingIndexes") { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS trackTitleBrowse
                ON track(title COLLATE NOCASE)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS trackArtistBrowse
                ON track(artistName COLLATE NOCASE, title COLLATE NOCASE)
                """)
        }

        // Plex used to answer "who sounds like this" with nothing at all — `artistInfo` returned
        // the biography and an empty list — so every artist page visited since the cache was
        // introduced holds an emptiness that is no longer true.
        migrator.registerMigration("v22-similarArtistsFromAnalysis") { db in
            try db.execute(sql: "DELETE FROM artistInfo WHERE similarArtistIds = ''")
        }

        // Playlists as the library sees them, so a song can be asked which playlists it is in.
        migrator.registerMigration("v23-playlistIndex") { db in
            try db.create(table: "indexedPlaylist") { table in
                table.primaryKey("id", .text)
                table.column("name", .text).notNull()
                // Nil until the songs behind it have been fetched. This is
                // what tells a lazy fill what it still owes.
                table.column("membersFetchedAt", .datetime)
            }
            try db.create(table: "playlistMember") { table in
                table.column("playlistId", .text).notNull()
                table.column("trackId", .text).notNull()
                table.primaryKey(["playlistId", "trackId"])
            }
            // The filter asks "which playlists is this song in", once per
            // song in the library, so the track side is the one that has to
            // be quick.
            try db.create(
                index: "playlistMember_trackId",
                on: "playlistMember",
                columns: ["trackId"]
            )
        }

        // What the server said about itself when the library was last walked, so the next sync can
        // ask whether anything has changed before fetching the answer.
        migrator.registerMigration("v24-libraryChangeToken") { db in
            try db.alter(table: "syncState") { table in
                table.add(column: "changeToken", .text)
                table.add(column: "lastFullSyncAt", .datetime)
            }
            // Every sync that has ever finished was a full walk, so the
            // existing date is the honest answer for both. Without this an
            // upgrade would look like a library that had never been walked.
            try db.execute(sql: "UPDATE syncState SET lastFullSyncAt = lastSyncAt")
        }

        // The search table rebuilt, for two reasons that both come from matching a phrase rather
        // than separate words.
        migrator.registerMigration("v25-searchPhrases") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS search")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search USING fts5(
                    kind UNINDEXED, itemId UNINDEXED, name, artist,
                    tokenize = 'trigram remove_diacritics 1'
                )
                """)
            try Self.repopulateSearch(db)
        }

        // The audience's own popularity figure — Plex's `ratingCount`, decoded but never stored
        // until now.
        migrator.registerMigration("v26-trackPopularity") { db in
            try db.alter(table: "track") { table in
                table.add(column: "popularity", .integer)
            }
        }

        // Two indexed columns rather than one, so a match can be told apart by *what* it matched —
        // see `repopulateSearch`.
        migrator.registerMigration("v28-searchColumns") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS search")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE search USING fts5(
                    kind UNINDEXED, itemId UNINDEXED, name, artist,
                    tokenize = 'trigram remove_diacritics 1'
                )
                """)
            try Self.repopulateSearch(db)
        }

        // Where a song sits in the queue, so the order songs were asked for survives the app being
        // killed — and so a queue can be listed in the order it will actually arrive.
        migrator.registerMigration("v29-downloadQueueOrder") { db in
            try db.alter(table: "download") { table in
                table.add(column: "queueOrder", .integer)
            }
            try db.create(
                index: "download_queueOrder",
                on: "download",
                columns: ["queueOrder"],
                ifNotExists: true
            )
        }


        // Beats per minute, as the server reports it — nothing here measures it.
        migrator.registerMigration("v30-trackBpm") { db in
            try db.alter(table: "track") { table in
                table.add(column: "bpm", .integer)
            }
        }

        // The MusicBrainz id a sync already learns about an artist (from Navidrome directly, from
        // Plex only when matched), and a cache of what a MusicBrainz lookup answered about that id
        // — a birthday, in practice, but general enough to hold a death…
        migrator.registerMigration("v31-artistLifeSpan") { db in
            try db.alter(table: "artist") { table in
                table.add(column: "musicBrainzId", .text)
            }
            try db.create(table: "artistLifeSpan") { t in
                t.primaryKey("artistId", .text)
                t.column("musicBrainzId", .text).notNull()
                // MusicBrainz's own `type` for the entity: "Person" or "Group" (occasionally
                // "Orchestra", "Choir" — anything that is not a person is treated as a group).
                t.column("kind", .text)
                // Present only when MusicBrainz gave a day-level date —
                // many artists have only a year, which this feature has no
                // use for and does not store here.
                t.column("beginDate", .text)
                t.column("beginMonth", .integer)
                t.column("beginDay", .integer)
                t.column("beginYear", .integer)
                // Day-level only, same as `beginDate`; a year-only death
                // date is dropped the same way.
                t.column("endDate", .text)
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(
                index: "artistLifeSpan_birthday",
                on: "artistLifeSpan",
                columns: ["beginMonth", "beginDay"]
            )
        }

        // The copy a song had before it was asked for again at another
        // quality, kept until the replacement has arrived. Null for
        // everything: nothing is being replaced until the next refetch.
        migrator.registerMigration("v32-downloadPreviousFile") { db in
            try db.alter(table: "download") { table in
                table.add(column: "previousFileName", .text)
                table.add(column: "previousVariant", .text)
            }
        }

        // The Born on This Day feature is gone, and with it the cache of what MusicBrainz answered.
        migrator.registerMigration("v33-dropArtistLifeSpan") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS artistLifeSpan_birthday")
            try db.execute(sql: "DROP TABLE IF EXISTS artistLifeSpan")
        }

        // What a server said about an album when it was asked, kept so the page can say it again
        // with no server to ask.
        migrator.registerMigration("v34-albumNotes") { db in
            try db.create(table: "albumNotes") { table in
                table.primaryKey("albumId", .text)
                table.column("notes", .text).notNull()
            }
        }

        // When an album was last asked about, so one the server has nothing to
        // say about is asked again after a while and not at every launch. A
        // row with no notes and a date is "asked, nothing there".
        migrator.registerMigration("v35-albumNotesChecked") { db in
            try db.alter(table: "albumNotes") { table in
                table.add(column: "checkedAt", .double)
            }
        }

        return migrator
    }

    /// Punctuation the indexed text is also stored without.
    private static let closedPunctuation = ["'", "\u{2019}"]
    private static let spacedPunctuation = [".", ",", "-", "\u{2013}", "_", "&", "/", "(", ")", "[", "]", ":", ";", "!", "?", "\""]

    /// Wraps a SQL text expression in the same folding, so the stored copy
    /// and the typed query are punctuated the same way — which is to say, not
    /// at all.
    private static func foldedSQL(_ expression: String) -> String {
        var sql = expression
        for character in closedPunctuation {
            let quoted = character == "'" ? "''" : character
            sql = "REPLACE(\(sql), '\(quoted)', '')"
        }
        for character in spacedPunctuation {
            sql = "REPLACE(\(sql), '\(character)', ' ')"
        }
        // Runs of spaces closed up, because a stop that already had a space after it leaves two:
        // "Pt.
        for _ in 0..<3 {
            sql = "REPLACE(\(sql), '  ', ' ')"
        }
        return "TRIM(\(sql))"
    }

    /// The same folding for what the user typed.
    static func folded(_ text: String) -> String {
        var folded = text
        for character in closedPunctuation {
            folded = folded.replacingOccurrences(of: character, with: "")
        }
        for character in spacedPunctuation {
            folded = folded.replacingOccurrences(of: character, with: " ")
        }
        // The same closing up, and by the same reasoning — both sides of the
        // comparison have to be spaced alike or neither finds the other.
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Rebuilds the search table from the entity tables.
    fileprivate static func repopulateSearch(_ db: Database) throws {
        if let ddl = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'search'"
        ) {
            try db.execute(sql: "DROP TABLE search")
            try db.execute(sql: ddl)
        } else {
            try db.execute(sql: "DELETE FROM search")
        }

        func both(_ expression: String) -> String {
            "\(expression) || ' ' || \(foldedSQL(expression))"
        }
        func insert(_ kind: String, table: String, name: String, artist: String) -> String {
            """
            INSERT INTO search (kind, itemId, name, artist)
            SELECT '\(kind)', id, \(both(name)), \(both(artist))
            FROM \(table)
            """
        }

        try db.execute(sql: insert(
            "artist", table: "artist",
            name: "name || ' ' || COALESCE(sortName, '')", artist: "''"
        ))
        try db.execute(sql: insert(
            "album", table: "album",
            name: "name", artist: "COALESCE(artistName, '')"
        ))
        try db.execute(sql: insert(
            "track", table: "track",
            name: "title", artist: "COALESCE(artistName, '')"
        ))
    }

    // MARK: - Sync writes

    /// The generation the next walk stamps its rows with.
    public func beginSyncGeneration() throws -> Int {
        localWrites.withLock { $0.syncStartedAt = Date() }
        return try database.read { db in
            let current = try Int.fetchOne(db, sql: "SELECT generation FROM syncState WHERE id = 1") ?? 0
            let newest = try Int.fetchOne(
                db,
                sql: """
                    SELECT MAX(
                        COALESCE((SELECT MAX(syncGen) FROM artist), 0),
                        COALESCE((SELECT MAX(syncGen) FROM album), 0),
                        COALESCE((SELECT MAX(syncGen) FROM track), 0)
                    )
                    """
            ) ?? 0
            return max(current, newest) + 1
        }
    }

    public func upsertArtists(_ artists: [Artist], generation: Int) throws {
        try database.write { db in
            for artist in artists {
                try ArtistRecord(artist, generation: generation).upsert(db)
            }
            try Self.reapplyWaitingChanges(db)
        }
    }

    public func upsertAlbums(_ albums: [Album], generation: Int) throws {
        try database.write { db in
            for album in albums {
                try AlbumRecord(album, generation: generation).upsert(db)
            }
            try Self.reapplyWaitingChanges(db)
        }
        // The artist eras were measured from these very rows.
        invalidateEraCache()
    }

    public func upsertTracks(_ tracks: [Track], generation: Int) throws {
        try database.write { db in
            for track in tracks {
                try TrackRecord(track, generation: generation).upsert(db)
            }
            try Self.reapplyWaitingChanges(db)
        }
    }

    /// Puts the ratings and hearts still waiting in the outbox back over rows a sync has just
    /// written from the server's older answer.
    static func reapplyWaitingChanges(_ db: Database) throws {
        guard try Bool.fetchOne(
            db, sql: "SELECT EXISTS(SELECT 1 FROM outbox WHERE kind <> 'play')"
        ) == true else { return }
        for table in ["track", "album", "artist"] {
            try db.execute(sql: """
                UPDATE \(table) SET rating = (
                    SELECT o.rating FROM outbox o
                    WHERE o.kind = 'rating' AND o.itemId = \(table).id
                )
                WHERE id IN (SELECT itemId FROM outbox WHERE kind = 'rating')
                """)
            try db.execute(sql: """
                UPDATE \(table) SET isFavorite = (
                    SELECT o.flag FROM outbox o
                    WHERE o.kind = 'favorite' AND o.mediaKind = ? AND o.itemId = \(table).id
                )
                WHERE id IN (SELECT itemId FROM outbox WHERE kind = 'favorite' AND mediaKind = ?)
                """, arguments: [table, table])
        }
    }

    /// Removes rows the finished sync did not see, rebuilds the search table, and records the new
    /// generation.
    public func finishSync(
        generation: Int,
        pruning: Bool = true,
        changeToken: String? = nil
    ) throws {
        let duringSync = localWrites.withLock { $0.sinceSyncBegan() }
        try database.write { db in
            if pruning {
                try db.execute(sql: "DELETE FROM artist WHERE syncGen < ?", arguments: [generation])
                try db.execute(sql: "DELETE FROM album WHERE syncGen < ?", arguments: [generation])
                try db.execute(sql: "DELETE FROM track WHERE syncGen < ?", arguments: [generation])
                // Waveforms outlive a sync, but not the track they describe.
                try db.execute(sql: "DELETE FROM waveform WHERE trackId NOT IN (SELECT id FROM track)")
                try db.execute(sql: "DELETE FROM albumNotes WHERE albumId NOT IN (SELECT id FROM album)")
            }
            try Self.repopulateSearch(db)
            // Whatever was said on this device during the walk, or is still
            // waiting to be told, is newer than what the walk read.
            try Self.reapplyWaitingChanges(db)
            for write in duringSync { try write.apply(db) }
            let now = Date()
            // Only a walk that was trusted with the sweep may say the library has been seen.
            let sawEverything: Date? = pruning ? now : nil
            try db.execute(
                sql: """
                    INSERT INTO syncState (id, generation, lastSyncAt, lastFullSyncAt, changeToken)
                    VALUES (1, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        generation = ?,
                        lastSyncAt = ?,
                        lastFullSyncAt = COALESCE(?, lastFullSyncAt),
                        changeToken = ?
                    """,
                arguments: [
                    generation, now, sawEverything, changeToken,
                    generation, now, sawEverything, changeToken,
                ]
            )
        }
        localWrites.withLock { $0.syncEnded() }
        // Rows the sync removed were part of the measurement too.
        invalidateEraCache()
    }

    /// Records that the server was asked whether anything had changed and said no.
    public func noteLibraryUnchanged() throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE syncState SET lastSyncAt = ? WHERE id = 1",
                arguments: [Date()]
            )
        }
    }

    // MARK: - Stats

    public struct Stats: Sendable {
        public let artistCount: Int
        public let albumCount: Int
        public let trackCount: Int
        public let lastSyncAt: Date?

        public var isEmpty: Bool { trackCount == 0 && albumCount == 0 }
    }

    /// When the last sync finished, on its own.
    public func lastSyncAt() throws -> Date? {
        try database.read { db in
            try Date.fetchOne(db, sql: "SELECT lastSyncAt FROM syncState WHERE id = 1")
        }
    }

    /// What a sync needs to know before it decides to do any work.
    public struct Checkpoint: Sendable {
        /// The token the server gave when the library was last walked, or
        /// nil if none was ever stored — which is every install before this
        /// existed, and every server that offers no such thing.
        public let changeToken: String?
        /// When every row was last seen.
        public let lastFullSyncAt: Date?

        public init(changeToken: String?, lastFullSyncAt: Date?) {
            self.changeToken = changeToken
            self.lastFullSyncAt = lastFullSyncAt
        }
    }

    public func checkpoint() throws -> Checkpoint {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT changeToken, lastFullSyncAt FROM syncState WHERE id = 1"
            ) else {
                return Checkpoint(changeToken: nil, lastFullSyncAt: nil)
            }
            return Checkpoint(changeToken: row[0], lastFullSyncAt: row[1])
        }
    }

    public func stats() throws -> Stats {
        try database.read { db in
            Stats(
                artistCount: try ArtistRecord.fetchCount(db),
                albumCount: try AlbumRecord.fetchCount(db),
                trackCount: try TrackRecord.fetchCount(db),
                lastSyncAt: try Date.fetchOne(db, sql: "SELECT lastSyncAt FROM syncState WHERE id = 1")
            )
        }
    }

    // MARK: - Snapshots

    /// Tables whose contents belong to the device that made them rather than to the library, and so
    /// are emptied out of a snapshot.
    private static let deviceLocalTables = [
        "waveform", "artistInfo", "outbox", "playlistMember",
        "download", "downloadedPlaylist",
    ]

    /// Writes a copy of the library — artists, albums, tracks and the playlist name index — to
    /// `destination`, small enough to send to another device.
    public func snapshot(to destination: URL) throws {
        // VACUUM INTO refuses to write a file that already exists, and the
        // -wal and -shm of a previous snapshot would be read as belonging to
        // the new one.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: destination.path + suffix)
            )
        }

        // GRDB's own vacuum(into:), rather than executing the statement in a
        // read block: VACUUM cannot run inside a transaction, which is what
        // `read` opens.
        try database.vacuum(into: destination.path)

        let copy = try DatabaseQueue(path: destination.path)
        try copy.write { db in
            if let ddl = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'search'"
            ) {
                try db.execute(sql: "DROP TABLE search")
                try db.execute(sql: ddl)
            }
            for table in Self.deviceLocalTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            // `playlistMember` is emptied above as a cache the receiver can rebuild — but what says
            // it needs rebuilding is a stamp kept in `indexedPlaylist`, which is part of the
            // catalogue and travels.
            try db.execute(sql: "UPDATE indexedPlaylist SET membersFetchedAt = NULL")
        }
        try copy.vacuum()
        try copy.close()

        // The journal files the trimming pass left behind. Whatever is in
        // them has been checkpointed by the vacuum, and sending them serves
        // only to make the transfer larger.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: destination.path + suffix)
            )
        }
    }

    // MARK: - Browsing reads

    /// A single artist by ID. Used to complete a partially-known artist —
    /// navigating from an album carries only the name and ID, since that is
    /// all the album record holds.
    public func artist(id: MediaID) throws -> Artist? {
        try database.read { db in
            try ArtistRecord.fetchOne(db, key: id.rawValue)?.domain(server: self.serverID)
        }
    }

    /// One artist, found by name rather than id.
    public func artist(named name: String) throws -> Artist? {
        try database.read { db in
            try ArtistRecord
                .filter(sql: "name = ? COLLATE NOCASE", arguments: [name])
                .fetchOne(db)?
                .domain(server: self.serverID)
        }
    }

    /// `downloadedOnly` is what offline browsing is made of: the same queries, narrowed to what has
    /// a file on the phone behind it.
    public func artists(
        downloadedOnly: Bool = false,
        order: ArtistOrder = .alphabetical,
        direction: SortDirection = .forward
    ) throws -> [Artist] {
        let shape = Self.artistOrderSQL(
            downloadedOnly: downloadedOnly, order: order, direction: direction
        )
        let sql = """
            SELECT \(Self.artistColumns)
            FROM artist
            \(shape.where.map { "WHERE \($0)" } ?? "")
            ORDER BY \(shape.orderBy)
            """
        return try database.read { db in
            try Self.wholeArtists(db, sql: sql, arguments: [], server: self.serverID)
        }
    }

    /// Albums with at least one song on the phone.
    private static let downloadedTrackClause = """
        id IN (SELECT trackId FROM download WHERE state = 'done')
        """

    private static let downloadedAlbumClause = """
        id IN (
            SELECT track.albumId FROM track
            JOIN download ON download.trackId = track.id
            WHERE download.state = 'done'
        )
        """

    /// Track ids with a file behind them, for marking a list rather than
    /// filtering it — an album page shows all its songs offline, with the
    /// ones that will not play told apart from the ones that will.
    public func downloadedTrackIDs() throws -> Set<String> {
        try database.read { db in
            try Set(String.fetchAll(
                db,
                sql: "SELECT trackId FROM download WHERE state = 'done'"
            ))
        }
    }

    // MARK: Browsing by letter

    /// The name an album files under, without the collation — `SUBSTR` wants
    /// the characters as they are stored, and the ordering applies its own.
    private static let albumInitialKey = "COALESCE(NULLIF(album.name, ''), album.artistName)"

    /// The same for an artist, honouring the server's own sort name so "The
    /// Beatles" files where the rest of the app already files it.
    private static let artistInitialKey = "COALESCE(artist.sortName, artist.name)"

    /// Every first character in the library, and how many albums begin with it.
    public func albumInitialCounts(downloadedOnly: Bool = false) throws -> [String: Int] {
        try initialCounts(
            table: "album",
            key: Self.albumInitialKey,
            where: downloadedOnly ? Self.downloadedAlbumClause : nil
        )
    }

    public func artistInitialCounts(downloadedOnly: Bool = false) throws -> [String: Int] {
        try initialCounts(
            table: "artist",
            key: Self.artistInitialKey,
            where: downloadedOnly ? Self.downloadedArtistClause : nil
        )
    }

    private func initialCounts(
        table: String,
        key: String,
        where clause: String?
    ) throws -> [String: Int] {
        let sql = """
            SELECT SUBSTR(TRIM(\(key)), 1, 1) AS initial, COUNT(*)
            FROM \(table)
            \(clause.map { "WHERE \($0)" } ?? "")
            GROUP BY initial
            """
        return try database.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: sql) {
                guard let initial: String = row[0], !initial.isEmpty else { continue }
                counts[initial, default: 0] += row[1] as Int
            }
            return counts
        }
    }

    /// Albums whose name begins with one of these characters, in the same order the alphabetical
    /// list uses.
    public func albums(initials: Set<String>, downloadedOnly: Bool = false) throws -> [Album] {
        guard !initials.isEmpty else { return [] }
        let wanted = initials.sorted()
        var clauses = [
            "SUBSTR(TRIM(\(Self.albumInitialKey)), 1, 1) IN (\(Self.placeholders(wanted.count)))"
        ]
        if downloadedOnly { clauses.append(Self.downloadedAlbumClause) }
        let sql = """
            SELECT \(Self.albumColumns)
            FROM album
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(Self.sql(for: .alphabeticalByName, direction: .forward).orderBy)
            """
        return try database.read { db in
            try Self.wholeAlbums(db, sql: sql, arguments: wanted, server: self.serverID)
        }
    }

    public func artists(initials: Set<String>, downloadedOnly: Bool = false) throws -> [Artist] {
        guard !initials.isEmpty else { return [] }
        let wanted = initials.sorted()
        var clauses = [
            "SUBSTR(TRIM(\(Self.artistInitialKey)), 1, 1) IN (\(Self.placeholders(wanted.count)))"
        ]
        if downloadedOnly { clauses.append(Self.downloadedArtistClause) }
        let sql = """
            SELECT \(Self.artistColumns)
            FROM artist
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(Self.artistOrderBy(.alphabetical, direction: .forward))
            """
        return try database.read { db in
            try Self.wholeArtists(db, sql: sql, arguments: wanted, server: self.serverID)
        }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Artists with at least one song on the phone. The album form of this
    /// already had a name; the artist form was written out by hand wherever
    /// it was needed.
    static let downloadedArtistClause = """
        artist.id IN (
            SELECT track.artistId FROM track
            JOIN download ON download.trackId = track.id
            WHERE download.state = 'done'
        )
        """

    /// Songs on the phone whose shape is not known yet.
    public func downloadedTracksWithoutWaveform() throws -> [MediaID] {
        let server = serverID
        return try database.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT download.trackId FROM download
                    LEFT JOIN waveform ON waveform.trackId = download.trackId
                    WHERE download.state = 'done' AND waveform.trackId IS NULL
                    """
            ).map { MediaID(server: server, rawValue: $0) }
        }
    }

    public func albums(
        filter: AlbumFilter,
        direction: SortDirection = .forward,
        offset: Int,
        limit: Int,
        downloadedOnly: Bool = false
    ) throws -> [Album] {
        let shape = Self.sql(for: filter, direction: direction)
        var clauses: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if downloadedOnly { clauses.append(Self.downloadedAlbumClause) }
        if let extra = shape.where {
            clauses.append(extra)
            arguments += shape.arguments
        }
        let sql = """
            SELECT \(Self.albumColumns)
            FROM album
            \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
            ORDER BY \(shape.orderBy)
            LIMIT ? OFFSET ?
            """
        return try database.read { db in
            try Self.wholeAlbums(
                db, sql: sql, arguments: arguments + [limit, offset], server: self.serverID
            )
        }
    }

    /// How a list of every song in the library is ordered.
    public enum SongOrder: String, CaseIterable, Sendable, Identifiable, Codable {
        case alphabeticalByTitle
        case alphabeticalByArtist
        case alphabeticalByAlbum
        case recentlyAdded
        case lastPlayed
        case mostPlayed
        case highestRated
        case year
        case duration

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .alphabeticalByTitle: "Title"
            case .alphabeticalByArtist: "Artist"
            case .alphabeticalByAlbum: "Album"
            case .recentlyAdded: "Date added"
            case .lastPlayed: "Date played"
            case .mostPlayed: "Play count"
            case .highestRated: "Rating"
            case .year: "Year"
            case .duration: "Length"
            }
        }

        /// The letter a row is filed under, for the jump bar — nothing for
        /// the orders that are not alphabetical.
        public var isAlphabetical: Bool {
            switch self {
            case .alphabeticalByTitle, .alphabeticalByArtist, .alphabeticalByAlbum: true
            default: false
            }
        }

        /// What this order is measuring, so a direction can be named for it
        /// rather than labelled "ascending" and left to be worked out.
        public var scale: SortScale {
            switch self {
            case .alphabeticalByTitle, .alphabeticalByArtist, .alphabeticalByAlbum: .alphabetical
            case .recentlyAdded, .lastPlayed: .recency
            case .mostPlayed, .highestRated: .quantity
            case .year: .recency
            case .duration: .quantity
            }
        }
    }

    /// How a list of every artist in the library is ordered.
    public enum ArtistOrder: String, CaseIterable, Sendable, Identifiable, Codable {
        case alphabetical
        case lastPlayed
        case mostPlayed
        case recentlyAdded
        case albumCount
        case highestRated

        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .alphabetical: "Name"
            case .lastPlayed: "Date played"
            case .mostPlayed: "Play count"
            case .recentlyAdded: "Date added"
            case .albumCount: "Album count"
            case .highestRated: "Rating"
            }
        }

        public var isAlphabetical: Bool { self == .alphabetical }

        public var scale: SortScale {
            switch self {
            case .alphabetical: .alphabetical
            case .lastPlayed, .recentlyAdded: .recency
            case .mostPlayed, .albumCount, .highestRated: .quantity
            }
        }
    }

    /// Which way a sort runs.
    public enum SortDirection: String, CaseIterable, Sendable, Identifiable, Codable {
        case forward
        case reverse

        public var id: String { rawValue }
    }

    /// What an order measures, which is what decides how its two directions
    /// should be named. "Ascending" and "descending" are true of all of them
    /// and useful for none: the answer wanted is "A–Z" or "Newest first".
    public enum SortScale: Sendable {
        case alphabetical
        case recency
        case quantity

        public func label(_ direction: SortDirection) -> String {
            switch (self, direction) {
            case (.alphabetical, .forward): "A–Z"
            case (.alphabetical, .reverse): "Z–A"
            case (.recency, .forward): "Newest first"
            case (.recency, .reverse): "Oldest first"
            case (.quantity, .forward): "Highest first"
            case (.quantity, .reverse): "Lowest first"
            }
        }
    }

    /// The ORDER BY a song order asks for, and the WHERE it implies.
    static func sql(
        for order: SongOrder,
        direction: SortDirection = .forward
    ) -> (where: String?, orderBy: String) {
        // The key the order is really about, and which way round it reads when it is running
        // forward.
        let shape: (where: String?, key: String, forwardIsDescending: Bool, tiebreak: String)
        switch order {
        case .alphabeticalByTitle:
            shape = (nil, "track.title COLLATE NOCASE", false, "track.id")
        case .alphabeticalByArtist:
            shape = (nil, "track.artistName COLLATE NOCASE", false,
                     "track.title COLLATE NOCASE, track.id")
        case .alphabeticalByAlbum:
            shape = (nil, "(SELECT \(albumByNameKey) FROM album WHERE album.id = track.albumId)",
                     false, "track.discNumber, track.trackNumber, track.id")
        case .recentlyAdded:
            shape = (nil, "(SELECT addedAt FROM album WHERE album.id = track.albumId)", true,
                     "track.title COLLATE NOCASE, track.id")
        case .lastPlayed:
            // Never played is not "played longest ago" — it is no answer to
            // the question, the same way `mostPlayed` leaves out what has
            // never been played rather than filing it at zero.
            shape = ("track.playedAt IS NOT NULL", "track.playedAt", true,
                     "track.title COLLATE NOCASE, track.id")
        case .mostPlayed:
            shape = ("track.playCount > 0", "track.playCount", true, "track.id")
        case .highestRated:
            shape = ("track.rating IS NOT NULL", "track.rating", true,
                     "track.title COLLATE NOCASE, track.id")
        case .year:
            shape = ("track.year IS NOT NULL", "track.year", true,
                     "track.title COLLATE NOCASE, track.id")
        case .duration:
            shape = ("track.duration IS NOT NULL", "track.duration", true,
                     "track.title COLLATE NOCASE, track.id")
        }

        let descending = direction == .forward ? shape.forwardIsDescending : !shape.forwardIsDescending
        // NULLS LAST on a descending key only: ascending already puts them
        // first, and the shapes that can hold nulls exclude them in `where`
        // anyway. Kept for `recentlyAdded`, which does not.
        let nulls = descending ? " DESC NULLS LAST" : " ASC"
        return (shape.where, "\(shape.key)\(nulls), \(shape.tiebreak)")
    }

    /// The ORDER BY an album filter asks for, the WHERE it implies, and the values that WHERE
    /// binds.
    static let albumByNameKey = "COALESCE(NULLIF(album.name, ''), album.artistName) COLLATE NOCASE"

    static func sql(
        for filter: AlbumFilter,
        direction: SortDirection = .forward
    ) -> (where: String?, arguments: [any DatabaseValueConvertible], orderBy: String) {
        let byName = Self.albumByNameKey
        // Turning a shape over flips the key it sorts on and nothing else — the tiebreaks after it
        // stay put, since a tie broken backwards is still a tie, and `album.id` last is what keeps
        // the same records filed under the same letters between visits.
        func run(_ key: String, _ forwardIsDescending: Bool, _ tiebreak: String) -> String {
            let descending = direction == .forward ? forwardIsDescending : !forwardIsDescending
            return "\(key)\(descending ? " DESC NULLS LAST" : " ASC")\(tiebreak)"
        }
        switch filter {
        case .alphabeticalByName:
            return (nil, [], run(byName, false, ", album.id"))
        case .alphabeticalByArtist:
            return (nil, [], run("album.artistName COLLATE NOCASE", false, ", \(byName), album.id"))
        case .recentlyAdded:
            return (nil, [], run("album.addedAt", true, ", album.id"))
        case .recentlyReleased:
            return ("album.releaseDate IS NOT NULL", [], run("album.releaseDate", true, ", album.id"))
        case .recentlyPlayed:
            return ("album.playedAt IS NOT NULL", [], run("album.playedAt", true, ", album.id"))
        case .mostPlayed:
            return ("album.playCount > 0", [], run("album.playCount", true, ", album.id"))
        case .highestRated:
            return ("album.rating IS NOT NULL", [], run("album.rating", true, ", album.id"))
        case .random:
            return (nil, [], "RANDOM()")
        case .rediscover:
            // Never played, or not for half a year.
            let cutoff = Date().addingTimeInterval(-Self.rediscoverAfter)
            return ("(album.playedAt IS NULL OR album.playedAt < ?)", [cutoff], "RANDOM()")
        case .favorites:
            return ("album.isFavorite", [], run(byName, false, ", album.id"))
        case .genre(let genre):
            return ("album.genre = ? COLLATE NOCASE", [genre], run(byName, false, ", album.id"))
        case .yearRange(let from, let to):
            return ("album.year BETWEEN ? AND ?", [from, to],
                    run("album.year", false, ", \(byName), album.id"))
        }
    }

    /// The songs most recently heard, newest first, each carrying the genre and year it is actually
    /// filed under.
    public func recentlyPlayedTracks(limit: Int = 400) throws -> [Track] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.*,
                       album.genre AS borrowedGenre,
                       album.year AS borrowedYear
                FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE track.playedAt IS NOT NULL AND track.title IS NOT NULL
                ORDER BY track.playedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                var record = try TrackRecord(row: row)
                if record.genre == nil { record.genre = row["borrowedGenre"] }
                if record.year == nil { record.year = row["borrowedYear"] }
                return record.domain(server: self.serverID)
            }
        }
    }

    /// The same listening history, with each song's `year` replaced by the era it actually belongs
    /// to.
    public func recentlyPlayedForMixes(limit: Int = 400) throws -> [Track] {
        let eras = try cachedActiveEraByArtist()
        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.*,
                       album.genre AS borrowedGenre,
                       album.year AS albumYear,
                       album.releaseDate AS albumReleaseDate,
                       album.isCollection AS albumIsCollection
                FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE track.playedAt IS NOT NULL AND track.title IS NOT NULL
                ORDER BY track.playedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                var record = try TrackRecord(row: row)
                if record.genre == nil { record.genre = row["borrowedGenre"] }
                let albumReleaseDate: Date? = row["albumReleaseDate"]
                let classification = TrackEra.resolve(
                    TrackEra.Signals(
                        trackOriginalYear: record.originalYear,
                        albumOriginalYear: albumReleaseDate.map(Self.year(of:)),
                        albumYear: row["albumYear"],
                        trackYear: record.year,
                        isCompilation: row["albumIsCollection"] ?? false,
                        artistEstimate: eras[(record.artistName ?? "").lowercased()]
                    )
                )
                record.year = classification.isLowConfidence ? nil : classification.year
                return record.domain(server: self.serverID)
            }
        }
    }

    /// What the library is made of, for deciding which mixes are worth offering.
    public func libraryShape() throws -> LibraryShape {
        let artistEras = try cachedActiveEraByArtist()
        return try database.read { db in
            // The names matter.
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(track.genre, album.genre) AS g,
                       \(Self.settledEraSQL) AS y,
                       track.artistName AS a,
                       COALESCE(album.isCollection, 0) AS coll,
                       COUNT(*) AS songs
                FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE COALESCE(track.genre, album.genre) IS NOT NULL
                  AND \(Self.ratingFloorSQL)
                GROUP BY g, y, a, coll
                """, arguments: [Self.favoriteRatingThreshold])

            var rawCounts: [String: Int] = [:]
            var rawByDecade: [String: [Int: Int]] = [:]
            for row in rows {
                guard let genre: String = row["g"] else { continue }
                let songs: Int = row["songs"] ?? 0
                rawCounts[genre, default: 0] += songs
                var era: Int? = row["y"]
                if era == nil, row["coll"] ?? 0 == 1, let artist: String = row["a"] {
                    // The compilations SQL cannot place on its own, counted through the same artist
                    // estimate the station will use — otherwise the seventies soul that only exists
                    // on modern collections could never be offered as a seventies mix, which is
                    // the…
                    era = artistEras[artist.lowercased()]
                }
                if let era {
                    rawByDecade[genre, default: [:]][(era / 10) * 10, default: 0] += songs
                }
            }

            let families = GenreFamily.families(of: rawCounts)
            var decades: [String: Int] = [:]
            for family in families {
                for member in family.members {
                    for (decade, songs) in rawByDecade[member] ?? [:] {
                        decades[
                            LibraryShape.key(genre: family.name, decade: decade),
                            default: 0
                        ] += songs
                    }
                }
            }

            return LibraryShape(
                totalTracks: try TrackRecord.fetchCount(db),
                families: families,
                decadeCounts: decades
            )
        }
    }

    /// Every tag each artist's records carry, pooled per artist.
    public func genreTagsByArtist() throws -> [String: Set<String>] {
        try database.read { db in
            var out: [String: Set<String>] = [:]
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT artistName AS a, genre AS g FROM album
                WHERE genre IS NOT NULL AND genre <> '' AND artistName IS NOT NULL
                """
            )
            for row in rows {
                guard let artist: String = row["a"], let genre: String = row["g"] else { continue }
                out[artist.lowercased(), default: []].insert(genre)
            }
            return out
        }
    }

    /// Each artist's musical era, for `EraAffinity` — the middle year of their own records, not the
    /// earliest or the latest.
    public func activeEraByArtist() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT artistName AS a, name AS n, year AS y, releaseDate AS r FROM album
                WHERE isCollection = 0 AND year IS NOT NULL
                    AND artistName IS NOT NULL AND artistName <> ''
                """
            )
            var years: [String: [Int]] = [:]
            for row in rows {
                guard let artist: String = row["a"], let year: Int = row["y"] else { continue }
                let title: String? = row["n"]
                // A "Greatest Hits" the server never flagged is the exact record this measurement
                // must not see: it is dated to its pressing and would drag the artist's era forward
                // by decades.
                if CompilationHeuristics.titleSuggestsCollection(title) { continue }
                // Where the record knows its own original date, that is the
                // year the artist was working in — a live album put out in
                // 2005 from a 1974 show should place them in the seventies.
                let original: Date? = row["r"]
                years[artist.lowercased(), default: []].append(
                    original.map(Self.year(of:)) ?? year
                )
            }

            // An artist who only ever turns up as a guest on other people's compilations — every
            // album crediting "Various Artists" rather than them, however many of their own songs
            // the library holds — never has a row above at all, however this…
            let trackRows = try Row.fetchAll(
                db,
                sql: """
                SELECT artistName AS a, originalYear AS y FROM track
                WHERE originalYear IS NOT NULL
                    AND artistName IS NOT NULL AND artistName <> ''
                """
            )
            var trackYears: [String: [Int]] = [:]
            for row in trackRows {
                guard let artist: String = row["a"], let year: Int = row["y"] else { continue }
                trackYears[artist.lowercased(), default: []].append(year)
            }
            for (artist, values) in trackYears where years[artist] == nil {
                years[artist] = values
            }

            return years.compactMapValues(Self.median)
        }
    }

    /// `activeEraByArtist()`, computed at most once per sync.
    public func cachedActiveEraByArtist() throws -> [String: Int] {
        if let cached = artistEraCache.withLock({ $0 }) { return cached }
        let fresh = try activeEraByArtist()
        artistEraCache.withLock { $0 = fresh }
        return fresh
    }

    /// Forgets the artist eras, because the albums they were measured from
    /// have changed.
    private func invalidateEraCache() {
        artistEraCache.withLock { $0 = nil }
        artistGenreTagCache.withLock { $0 = nil }
    }

    /// `genreTagsByArtist()`, computed at most once per sync. Starting any
    /// radio or mix asked for the whole-library map on the main actor every
    /// time; the albums it is read from only change when a sync does.
    public func cachedGenreTagsByArtist() throws -> [String: Set<String>] {
        if let cached = artistGenreTagCache.withLock({ $0 }) { return cached }
        let fresh = try genreTagsByArtist()
        artistGenreTagCache.withLock { $0 = fresh }
        return fresh
    }

    private static func year(of date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.component(.year, from: date)
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Several sleeves for a genre mix, most-played first.
    public func artworksForMix(genres: [String], decade: Int?, limit: Int = 4) throws -> [ArtworkID] {
        guard !genres.isEmpty, limit > 0 else { return [] }
        return try database.read { db in
            let places = genres.map { _ in "?" }.joined(separator: ", ")
            var clauses = [
                "COALESCE(track.genre, album.genre) IN (\(places))",
                "track.artworkId IS NOT NULL",
            ]
            var arguments: [any DatabaseValueConvertible] = genres
            if let decade {
                // The era the song settles on, so a mix's sleeves and its names come from the
                // records it will actually play — see `settledEraSQL`.
                clauses.append("\(Self.settledEraSQL) >= ? AND \(Self.settledEraSQL) < ?")
                arguments.append(decade)
                arguments.append(decade + 10)
            }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.artworkId AS art, MAX(COALESCE(track.playCount, 0)) AS plays
                FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE \(clauses.joined(separator: " AND "))
                GROUP BY track.albumId
                ORDER BY plays DESC, RANDOM()
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                (row["art"] as String?).map { ArtworkID(server: self.serverID, rawValue: $0) }
            }
        }
    }

    /// The artists a genre mix will mostly be, biggest first.
    public func topArtists(genres: [String], decade: Int?, limit: Int = 4) throws -> [String] {
        guard !genres.isEmpty, limit > 0 else { return [] }
        return try database.read { db in
            let places = genres.map { _ in "?" }.joined(separator: ", ")
            var clauses = [
                "COALESCE(track.genre, album.genre) IN (\(places))",
                "track.artistName IS NOT NULL AND track.artistName <> ''",
            ]
            var arguments: [any DatabaseValueConvertible] = genres
            if let decade {
                // The era the song settles on, so a mix's sleeves and its names come from the
                // records it will actually play — see `settledEraSQL`.
                clauses.append("\(Self.settledEraSQL) >= ? AND \(Self.settledEraSQL) < ?")
                arguments.append(decade)
                arguments.append(decade + 10)
            }
            arguments.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT track.artistName AS a, COUNT(*) AS n FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE \(clauses.joined(separator: " AND "))
                GROUP BY track.artistName COLLATE NOCASE
                ORDER BY n DESC
                LIMIT ?
                """, arguments: StatementArguments(arguments))
            return rows.compactMap { $0["a"] as String? }
        }
    }

    /// What these songs are rated, for the ones that are rated at all.
    public func ratings(forTrackIDs ids: [MediaID]) throws -> [String: Double] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            var out: [String: Double] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 400).map({
                Array(ids[$0..<min($0 + 400, ids.count)])
            }) {
                let places = chunk.map { _ in "?" }.joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, rating FROM track WHERE id IN (\(places)) AND rating IS NOT NULL",
                    arguments: StatementArguments(chunk.map(\.rawValue))
                )
                for row in rows {
                    if let id: String = row["id"], let rating: Double = row["rating"] {
                        out[id] = rating
                    }
                }
            }
            return out
        }
    }

    /// How long these songs run, for the ones the library still has.
    public func durations(forTrackIDs ids: [MediaID]) throws -> [MediaID: TimeInterval] {
        guard !ids.isEmpty else { return [:] }
        return try database.read { db in
            var out: [MediaID: TimeInterval] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 400).map({
                Array(ids[$0..<min($0 + 400, ids.count)])
            }) {
                let places = chunk.map { _ in "?" }.joined(separator: ", ")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT id, duration FROM track WHERE id IN (\(places)) AND duration IS NOT NULL",
                    arguments: StatementArguments(chunk.map(\.rawValue))
                )
                for row in rows {
                    if let id: String = row["id"], let duration: TimeInterval = row["duration"] {
                        out[MediaID(server: serverID, rawValue: id)] = duration
                    }
                }
            }
            return out
        }
    }

    /// Every one of these songs the library still has, in the same order and with the same
    /// duplicates as `ids`; a missing one is `nil` rather than dropping the slot, so a caller can
    /// tell "gone" from "moved."
    public func tracks(ids: [MediaID]) throws -> [Track?] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var byID: [String: Track] = [:]
            for chunk in stride(from: 0, to: ids.count, by: 500).map({
                Array(ids[$0..<min($0 + 500, ids.count)])
            }) {
                let records = try TrackRecord.filter(keys: chunk.map(\.rawValue)).fetchAll(db)
                for record in records {
                    byID[record.id] = record.domain(server: serverID)
                }
            }
            return ids.map { byID[$0.rawValue] }
        }
    }

    /// How many songs the library holds of each artist, biggest first.
    public func artistSongCounts(limit: Int = 400) throws -> [(name: String, songs: Int)] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artistName AS a, COUNT(*) AS n FROM track
                WHERE artistName IS NOT NULL AND artistName <> ''
                GROUP BY artistName COLLATE NOCASE
                ORDER BY n DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row in
                guard let name: String = row["a"], let n: Int = row["n"] else { return nil }
                return (name, n)
            }
        }
    }

    /// The picture for an artist, for a mix that is about them.
    public func artistArtwork(named name: String) throws -> ArtworkID? {
        try database.read { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT artworkId AS art FROM artist WHERE name = ? COLLATE NOCASE AND artworkId IS NOT NULL LIMIT 1",
                arguments: [name]
            ), let raw: String = row["art"] {
                return ArtworkID(server: self.serverID, rawValue: raw)
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT artworkId AS art FROM album
                WHERE artistName = ? COLLATE NOCASE AND artworkId IS NOT NULL
                ORDER BY COALESCE(playCount, 0) DESC
                LIMIT 1
                """, arguments: [name])
            guard let raw: String = row?["art"] else { return nil }
            return ArtworkID(server: self.serverID, rawValue: raw)
        }
    }

    /// A sleeve to draw a genre or decade mix with — the most-played record
    /// that belongs to it, so the card shows music rather than a chip.
    public func artworkForMix(genres: [String], decade: Int?) throws -> ArtworkID? {
        guard !genres.isEmpty else { return nil }
        return try database.read { db in
            let places = genres.map { _ in "?" }.joined(separator: ", ")
            var clauses = [
                "COALESCE(track.genre, album.genre) IN (\(places))",
                "track.artworkId IS NOT NULL",
            ]
            var arguments: [any DatabaseValueConvertible] = genres
            if let decade {
                // The era the song settles on, so a mix's sleeves and its names come from the
                // records it will actually play — see `settledEraSQL`.
                clauses.append("\(Self.settledEraSQL) >= ? AND \(Self.settledEraSQL) < ?")
                arguments.append(decade)
                arguments.append(decade + 10)
            }
            let row = try Row.fetchOne(db, sql: """
                SELECT track.artworkId AS art FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE \(clauses.joined(separator: " AND "))
                ORDER BY COALESCE(track.playCount, 0) DESC, RANDOM()
                LIMIT 1
                """, arguments: StatementArguments(arguments))
            guard let raw: String = row?["art"] else { return nil }
            return ArtworkID(server: self.serverID, rawValue: raw)
        }
    }

    /// Every song, in the given order.
    public func tracks(
        order: SongOrder,
        direction: SortDirection = .forward,
        offset: Int = 0,
        limit: Int = 100_000,
        downloadedOnly: Bool = false
    ) throws -> [Track] {
        let shape = Self.sql(for: order, direction: direction)
        var clauses: [String] = []
        if downloadedOnly { clauses.append(Self.downloadedTrackClause) }
        if let extra = shape.where { clauses.append(extra) }
        let sql = """
            SELECT id, title, albumName, albumId, artistName, artistId,
                   trackNumber, discNumber, duration, year, originalYear, genre,
                   codec, contentType, bitRateKbps, sampleRate, bitDepth,
                   channelCount, fileSize, artworkId, rgTrackGain, rgAlbumGain,
                   rgTrackPeak, rgAlbumPeak, isFavorite, rating, playCount, playedAt
            FROM track
            \(clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND "))
            ORDER BY \(shape.orderBy)
            LIMIT ? OFFSET ?
            """
        return try database.read { db in
            try Self.wholeTracks(db, sql: sql, arguments: [limit, offset], server: self.serverID)
        }
    }

    /// Whole songs, stepped from a cursor and taken by column position.
    static func wholeTracks(
        _ db: Database,
        sql: String,
        arguments: [any DatabaseValueConvertible],
        server: ServerID
    ) throws -> [Track] {
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments))
        var out: [Track] = []
        out.reserveCapacity(4096)
        while let row = try cursor.next() {
            let albumID: String? = row[3]
            let artistID: String? = row[5]
            let artworkID: String? = row[19]
            let rgTrackGain: Double? = row[20]
            let rgAlbumGain: Double? = row[21]
            let rgTrackPeak: Double? = row[22]
            let rgAlbumPeak: Double? = row[23]
            let rating: Double? = row[25]
            let replayGain: ReplayGain? = (rgTrackGain ?? rgAlbumGain ?? rgTrackPeak ?? rgAlbumPeak) == nil
                ? nil
                : ReplayGain(
                    trackGain: rgTrackGain, albumGain: rgAlbumGain,
                    trackPeak: rgTrackPeak, albumPeak: rgAlbumPeak
                )
            out.append(Track(
                id: MediaID(server: server, rawValue: row[0]),
                title: row[1],
                albumName: row[2],
                albumID: albumID.map { MediaID(server: server, rawValue: $0) },
                artistName: row[4],
                artistID: artistID.map { MediaID(server: server, rawValue: $0) },
                trackNumber: row[6],
                discNumber: row[7],
                duration: row[8],
                year: row[9],
                originalYear: row[10],
                genre: row[11],
                codec: row[12],
                contentType: row[13],
                bitRateKbps: row[14],
                sampleRate: row[15],
                bitDepth: row[16],
                channelCount: row[17],
                fileSize: row[18],
                artwork: artworkID.map { ArtworkID(server: server, rawValue: $0) },
                replayGain: replayGain,
                isFavorite: row[24],
                rating: rating.flatMap(StarRating.init),
                playCount: row[26],
                playedAt: row[27]
            ))
        }
        return out
    }

    /// The columns `Album` is built from, in the order `wholeAlbums` reads them by position.
    static let albumColumns = """
        album.id, album.name, album.artistId, album.artistName, album.year,
        album.genre, album.trackCount, album.duration, album.artworkId,
        album.addedAt, album.playedAt, album.playCount, album.isFavorite,
        album.rating, album.releaseTypes, album.isCompilation, album.recordLabel,
        album.releaseDate, album.criticRating, album.review
        """

    /// Whole albums, stepped from a cursor and taken by column position — the album twin of
    /// `wholeTracks`, for the same reason: the cost of a read this size is per column, and a cursor
    /// taken by position copies nothing and looks up no names.
    static func wholeAlbums(
        _ db: Database,
        sql: String,
        arguments: [any DatabaseValueConvertible],
        server: ServerID
    ) throws -> [Album] {
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments))
        var out: [Album] = []
        out.reserveCapacity(1024)
        while let row = try cursor.next() {
            let artistID: String? = row[2]
            let artworkID: String? = row[8]
            let rating: Double? = row[13]
            let types: String = row[14]
            out.append(Album(
                id: MediaID(server: server, rawValue: row[0]),
                name: row[1],
                artistName: row[3],
                artistID: artistID.map { MediaID(server: server, rawValue: $0) },
                year: row[4],
                genre: row[5],
                trackCount: row[6],
                duration: row[7],
                artwork: artworkID.map { ArtworkID(server: server, rawValue: $0) },
                addedAt: row[9],
                playedAt: row[10],
                playCount: row[11],
                isFavorite: row[12],
                rating: rating.flatMap(StarRating.init),
                releaseTypes: types.split(separator: ",").compactMap { ReleaseType(rawValue: String($0)) },
                isCompilation: row[15],
                recordLabel: row[16],
                releaseDate: row[17],
                criticRating: row[18],
                review: row[19]
            ))
        }
        return out
    }

    /// The columns `Artist` is built from, in the order `wholeArtists` reads
    /// them by position. `syncGen` is the only column `ArtistRecord` carries
    /// that `Artist` has no field for.
    static let artistColumns = """
        artist.id, artist.name, artist.sortName, artist.albumCount,
        artist.artworkId, artist.isFavorite, artist.rating
        """

    /// Whole artists, stepped from a cursor and taken by column position — the artist twin of
    /// `wholeTracks`/`wholeAlbums`.
    static func wholeArtists(
        _ db: Database,
        sql: String,
        arguments: [any DatabaseValueConvertible],
        server: ServerID
    ) throws -> [Artist] {
        let cursor = try Row.fetchCursor(db, sql: sql, arguments: StatementArguments(arguments))
        var out: [Artist] = []
        out.reserveCapacity(1024)
        while let row = try cursor.next() {
            let artworkID: String? = row[4]
            let rating: Double? = row[6]
            out.append(Artist(
                id: MediaID(server: server, rawValue: row[0]),
                name: row[1],
                sortName: row[2],
                albumCount: row[3],
                artwork: artworkID.map { ArtworkID(server: server, rawValue: $0) },
                isFavorite: row[5],
                rating: rating.flatMap(StarRating.init)
            ))
        }
        return out
    }

    /// The ORDER BY the artist list asks for, and the WHERE `downloadedOnly` implies.
    private static func artistOrderSQL(
        downloadedOnly: Bool,
        order: ArtistOrder = .alphabetical,
        direction: SortDirection = .forward
    ) -> (where: String?, orderBy: String) {
        let clause = downloadedOnly ? """
            artist.id IN (
                SELECT track.artistId FROM track
                JOIN download ON download.trackId = track.id
                WHERE download.state = 'done'
            )
            """ : nil
        return (clause, artistOrderBy(order, direction: direction))
    }

    /// An artist has no date of its own — nothing about when they were last played, or how much, is
    /// stored against the artist row.
    static func artistOrderBy(_ order: ArtistOrder, direction: SortDirection) -> String {
        let byName = "COALESCE(artist.sortName, artist.name) COLLATE NOCASE"
        let shape: (key: String, forwardIsDescending: Bool)
        switch order {
        case .alphabetical:
            shape = (byName, false)
        case .lastPlayed:
            shape = ("(SELECT MAX(album.playedAt) FROM album WHERE album.artistId = artist.id)", true)
        case .mostPlayed:
            shape = ("(SELECT SUM(COALESCE(album.playCount, 0)) FROM album WHERE album.artistId = artist.id)", true)
        case .albumCount:
            shape = ("(SELECT COUNT(*) FROM album WHERE album.artistId = artist.id)", true)
        case .highestRated:
            shape = ("artist.rating", true)
        case .recentlyAdded:
            shape = ("(SELECT MAX(album.addedAt) FROM album WHERE album.artistId = artist.id)", true)
        }
        let descending = direction == .forward ? shape.forwardIsDescending : !shape.forwardIsDescending
        // An artist with nothing to answer with — never played, unrated —
        // goes last either way rather than crowding the top of a reversed
        // list, which is what a bare ASC on a null column would do.
        let sorted = descending ? "\(shape.key) DESC NULLS LAST" : "\(shape.key) ASC NULLS LAST"
        // Always ends on the name and then the id: two artists with the same
        // answer would otherwise change places between one visit and the
        // next, the same way every other order in this file guards against.
        return order == .alphabetical
            ? "\(sorted), artist.id"
            : "\(sorted), \(byName), artist.id"
    }

    public func albums(forArtist id: MediaID, downloadedOnly: Bool = false) throws -> [Album] {
        try database.read { db in
            var request = AlbumRecord.filter(sql: "artistId = ?", arguments: [id.rawValue])
            if downloadedOnly {
                request = request.filter(sql: Self.downloadedAlbumClause)
            }
            return try request
                .order(sql: "year, name COLLATE NOCASE")
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }
        }
    }

    // MARK: - Artist page cache

    /// Everything an artist page needs that browsing does not supply.
    /// Resolved into domain values so the page can paint without a network
    /// round trip.
    public struct CachedArtistPage: Sendable {
        public var biography: String?
        public var similarArtists: [Artist]
        public var topTracks: [Track]
        public var fetchedAt: Date

        /// Whether a background refresh is worth making.
        public func isStale(after interval: TimeInterval = 60 * 60 * 24 * 7) -> Bool {
            Date().timeIntervalSince(fetchedAt) > interval
        }
    }

    public func cachedArtistPage(for id: MediaID) throws -> CachedArtistPage? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM artistInfo WHERE artistId = ?",
                arguments: [id.rawValue]
            ) else { return nil }

            let similarIDs = (row["similarArtistIds"] as String)
                .split(separator: "\u{1}").map(String.init)
            let trackIDs = (row["topTrackIds"] as String)
                .split(separator: "\u{1}").map(String.init)

            // Keep the stored order; `fetchAll(keys:)` does not guarantee it.
            let similarByID = Dictionary(
                grouping: try ArtistRecord.fetchAll(db, keys: similarIDs),
                by: \.id
            )
            let tracksByID = Dictionary(
                grouping: try TrackRecord.fetchAll(db, keys: trackIDs),
                by: \.id
            )

            return CachedArtistPage(
                biography: row["biography"],
                similarArtists: similarIDs.compactMap { similarByID[$0]?.first }
                    .map { $0.domain(server: self.serverID) },
                topTracks: trackIDs.compactMap { tracksByID[$0]?.first }
                    .map { $0.domain(server: self.serverID) },
                fetchedAt: row["fetchedAt"]
            )
        }
    }

    public func storeArtistPage(
        for id: MediaID,
        biography: String?,
        similarArtistIDs: [MediaID],
        topTrackIDs: [MediaID],
        fetchedAt: Date = Date()
    ) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO artistInfo (artistId, biography, similarArtistIds, topTrackIds, fetchedAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(artistId) DO UPDATE SET
                    biography = excluded.biography,
                    similarArtistIds = excluded.similarArtistIds,
                    topTrackIds = excluded.topTrackIds,
                    fetchedAt = excluded.fetchedAt
                """, arguments: [
                    id.rawValue,
                    biography,
                    // Server IDs may contain commas, so use a separator that
                    // cannot appear in one.
                    similarArtistIDs.map(\.rawValue).joined(separator: "\u{1}"),
                    topTrackIDs.map(\.rawValue).joined(separator: "\u{1}"),
                    fetchedAt,
                ])
        }
    }

    /// An artist's own releases, split by category for the artist page.
    /// Ordering within a group is newest first, which reads better than
    /// alphabetical for a discography.
    public func releaseGroups(forArtist id: MediaID) throws -> [(type: ReleaseType, albums: [Album])] {
        let albums = try self.albums(forArtist: id)
        let grouped = Dictionary(grouping: albums) { $0.primaryReleaseType }
        return ReleaseType.allCases.compactMap { type in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            let sorted = group.sorted { ($0.year ?? 0, $0.name) > ($1.year ?? 0, $1.name) }
            return (type, sorted)
        }
    }

    /// Albums the artist appears on without being the album artist — features, compilations,
    /// soundtracks.
    public func appearsOn(
        artistID: MediaID,
        artistName: String,
        downloadedOnly: Bool = false
    ) throws -> [Album] {
        // Only records with one of their songs actually on the phone, when
        // asked from the Downloads tab: a record this artist appears on but
        // that was never kept opens onto nothing.
        let kept = downloadedOnly
            ? "AND track.id IN (SELECT trackId FROM download WHERE state = 'done')"
            : ""
        return try database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT DISTINCT album.* FROM album
                JOIN track ON track.albumId = album.id
                WHERE (album.artistId IS NULL OR album.artistId <> ?)
                  AND (track.artistId = ? OR track.artistName = ? COLLATE NOCASE)
                  \(kept)
                ORDER BY album.year DESC, album.name COLLATE NOCASE
                """, arguments: [id(of: artistID), id(of: artistID), artistName])
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// The artist's most-played tracks according to local play counts.
    public func topTracks(forArtist id: MediaID, limit: Int) throws -> [Track] {
        try artistSongs(
            where: "track.artistId = ? AND COALESCE(track.playCount, 0) > 0",
            arguments: [id.rawValue],
            order: "COALESCE(track.playCount, 0) DESC",
            limit: limit
        )
    }

    /// A rating of this or better makes a track a favourite.
    public static let favoriteRatingThreshold = 2.5

    /// The line the Highly Rated station itself draws — its own, higher bar than
    /// `favoriteRatingThreshold`, which every station already holds to as the floor beneath which
    /// nothing plays at all.
    public static let highlyRatedThreshold = 3.0

    /// The long version of the favourites shelf, best first, held to the same rule about a song
    /// appearing once — and to the same rating floor.
    public func ratedTracks(forArtist id: MediaID, limit: Int = 500) throws -> [Track] {
        try artistSongs(
            where: "track.artistId = ? AND track.rating >= ?",
            arguments: [id.rawValue, Self.favoriteRatingThreshold],
            order: "track.rating DESC",
            limit: limit
        )
    }

    /// What the listener has rated at `favoriteRatingThreshold` or better.
    public func favoriteTracks(forArtist id: MediaID, limit: Int) throws -> [Track] {
        try artistSongs(
            where: "track.artistId = ? AND track.rating >= ?",
            arguments: [id.rawValue, Self.favoriteRatingThreshold],
            order: "track.rating DESC",
            limit: limit
        )
    }

    /// The artist page's song lists, with a song's other pressings folded away.
    private func artistSongs(
        where condition: String,
        arguments: StatementArguments,
        order: String,
        limit: Int
    ) throws -> [Track] {
        let sql = """
            SELECT track.*,
                   album.year AS albumYear,
                   album.isCollection AS albumIsCollection,
                   EXISTS (
                       SELECT 1 FROM download
                       WHERE download.trackId = track.id AND download.state = 'done'
                   ) AS isDownloaded
            FROM track
            LEFT JOIN album ON album.id = track.albumId
            WHERE \(condition)
            ORDER BY \(order),
                     COALESCE(track.albumName, ''),
                     COALESCE(track.discNumber, 1),
                     COALESCE(track.trackNumber, 0)
            """
        var draw = min(max(limit * 20, 1_000), 4_000)
        while true {
            let copies: [DuplicateSongs.Copy] = try database.read { db in
                try Row.fetchAll(db, sql: "\(sql)\nLIMIT \(draw)", arguments: arguments)
                    .map { row in
                        let record = try TrackRecord(row: row)
                        let albumYear: Int? = row["albumYear"]
                        return DuplicateSongs.Copy(
                            track: record.domain(server: self.serverID),
                            isFromCollection: row["albumIsCollection"] ?? false,
                            recordYear: albumYear ?? record.year,
                            isDownloaded: row["isDownloaded"] ?? false
                        )
                    }
            }
            let songs = DuplicateSongs.pruned(copies)
            // Enough songs, or there were no more rows to have — either way
            // this is the whole answer.
            if songs.count >= limit || copies.count < draw {
                return Array(songs.prefix(limit))
            }
            draw *= 4
        }
    }

    // MARK: - Downloads

    public func downloads() throws -> [DownloadRecord] {
        try database.read { db in
            try DownloadRecord.order(sql: "addedAt DESC").fetchAll(db)
        }
    }

    /// Whether any of a record's songs are actually on the phone.
    public func hasDownloadedTracks(inAlbum id: MediaID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM track
                    JOIN download ON download.trackId = track.id
                    WHERE track.albumId = ? AND download.state = 'done'
                )
                """, arguments: [id.rawValue]) ?? false
        }
    }

    /// The same question about everything an artist made.
    public func hasDownloadedTracks(byArtist id: MediaID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM track
                    JOIN download ON download.trackId = track.id
                    WHERE track.artistId = ? AND download.state = 'done'
                )
                """, arguments: [id.rawValue]) ?? false
        }
    }

    /// Whether any of a record's songs are *not* on the phone.
    public func hasUndownloadedTracks(inAlbum id: MediaID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM track
                    LEFT JOIN download
                        ON download.trackId = track.id AND download.state = 'done'
                    WHERE track.albumId = ? AND download.trackId IS NULL
                )
                """, arguments: [id.rawValue]) ?? false
        }
    }

    public func hasUndownloadedTracks(byArtist id: MediaID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM track
                    LEFT JOIN download
                        ON download.trackId = track.id AND download.state = 'done'
                    WHERE track.artistId = ? AND download.trackId IS NULL
                )
                """, arguments: [id.rawValue]) ?? false
        }
    }

    public func download(forTrack id: MediaID) throws -> DownloadRecord? {
        try database.read { db in
            try DownloadRecord.fetchOne(db, key: id.rawValue)
        }
    }

    /// The rows for several songs, in one read.
    public func downloads(forTracks ids: [MediaID]) throws -> [DownloadRecord] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var found: [DownloadRecord] = []
            for start in stride(from: 0, to: ids.count, by: 400) {
                let chunk = ids[start..<min(start + 400, ids.count)].map(\.rawValue)
                found += try DownloadRecord.fetchAll(db, keys: chunk)
            }
            return found
        }
    }

    public func saveDownload(_ record: DownloadRecord) throws {
        try database.write { db in
            try record.save(db)
        }
    }

    public func deleteDownload(forTrack id: MediaID) throws {
        _ = try database.write { db in
            try DownloadRecord.deleteOne(db, key: id.rawValue)
        }
    }

    /// Every download row, in one transaction.
    public func deleteAllDownloads() throws {
        _ = try database.write { db in
            try DownloadRecord.deleteAll(db)
        }
    }

    /// Several rows in one transaction.
    public func deleteDownloads(forTracks ids: [MediaID]) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            for id in ids {
                _ = try DownloadRecord.deleteOne(db, key: id.rawValue)
            }
        }
    }

    public func saveDownloads(_ records: [DownloadRecord]) throws {
        guard !records.isEmpty else { return }
        try database.write { db in
            for record in records { try record.save(db) }
        }
    }

    /// What is still owed, in the order it was asked for.
    public func queuedDownloads() throws -> [DownloadRecord] {
        try database.read { db in
            try DownloadRecord
                .filter(sql: "queueOrder IS NOT NULL")
                .order(sql: "queueOrder")
                .fetchAll(db)
        }
    }

    /// The last place given out, so the next song asked for goes behind
    /// everything already waiting rather than in among it.
    public func highestQueueOrder() throws -> Int? {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(queueOrder) FROM download")
        }
    }

    /// Forgets the order of every row, which is what the end of a run means.
    public func clearQueueOrder() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE download SET queueOrder = NULL")
        }
    }

    /// The tracks of an album, in playing order — what a "download this
    /// album" request expands to. Whole tracks rather than ids: what is
    /// downloaded depends on the codec and bit rate of each one.
    public func tracks(inAlbum id: MediaID) throws -> [Track] {
        try database.read { db in
            try TrackRecord
                .filter(sql: "albumId = ?", arguments: [id.rawValue])
                .order(sql: "COALESCE(discNumber, 1), COALESCE(trackNumber, 0), title")
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// Every track by an artist, album by album.
    public func tracks(byArtist id: MediaID) throws -> [Track] {
        try database.read { db in
            try TrackRecord
                .filter(sql: "artistId = ?", arguments: [id.rawValue])
                .order(sql: "COALESCE(albumName, ''), COALESCE(discNumber, 1), COALESCE(trackNumber, 0), title")
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }
        }
    }

    // MARK: - Downloaded playlists

    public func saveDownloadedPlaylist(_ record: DownloadedPlaylistRecord) throws {
        try database.write { db in try record.save(db) }
    }

    public func downloadedPlaylists() throws -> [DownloadedPlaylistRecord] {
        try database.read { db in
            try DownloadedPlaylistRecord.order(sql: "name COLLATE NOCASE").fetchAll(db)
        }
    }

    public func downloadedPlaylist(id: MediaID) throws -> DownloadedPlaylistRecord? {
        try database.read { db in try DownloadedPlaylistRecord.fetchOne(db, key: id.rawValue) }
    }

    public func deleteDownloadedPlaylist(id: MediaID) throws {
        _ = try database.write { db in
            try DownloadedPlaylistRecord.deleteOne(db, key: id.rawValue)
        }
    }

    // MARK: - Playlists the filter can ask about

    /// Records the playlists a server has, by name.
    public func saveIndexedPlaylists(_ playlists: [IndexedPlaylistRecord]) throws {
        try database.write { db in
            let keep = Set(playlists.map(\.id))
            for existing in try IndexedPlaylistRecord.fetchAll(db) where !keep.contains(existing.id) {
                try db.execute(
                    sql: "DELETE FROM playlistMember WHERE playlistId = ?",
                    arguments: [existing.id]
                )
                try existing.delete(db)
            }
            for playlist in playlists {
                // The fetch stamp belongs to the membership, not to the name,
                // so a rename must not look like a reason to fetch again.
                let held = try IndexedPlaylistRecord.fetchOne(db, key: playlist.id)
                var row = playlist
                row.membersFetchedAt = held?.membersFetchedAt
                try row.save(db)
            }
        }
    }

    /// The playlists whose names match, that nothing has fetched the songs of yet — the work a
    /// filter has to do before it can answer.
    public func playlistsAwaitingMembers(
        matching text: String,
        now: Date = Date()
    ) throws -> [IndexedPlaylistRecord] {
        let staleBefore = now.addingTimeInterval(-Self.membersTTL)
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try database.read { db in
            // Folded the same way the rule itself is — see `compileText`.
            try IndexedPlaylistRecord
                .filter(
                    sql: "(membersFetchedAt IS NULL OR membersFetchedAt < ?) AND swiftLowercaseString(name) LIKE ? ESCAPE '\\'",
                    arguments: [staleBefore, "%\(escaped.lowercased())%"]
                )
                .fetchAll(db)
        }
    }

    /// How long a fetched membership is believed.
    public static let membersTTL: TimeInterval = 30 * 60

    /// Marks a playlist's songs as out of date after this app changed it, so
    /// the next question about it fetches them again. The old rows stay until
    /// then: a rule answered from slightly old membership beats one answered
    /// from none while the fetch is in flight.
    public func invalidateMembers(ofPlaylist id: String) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE indexedPlaylist SET membersFetchedAt = NULL WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// What is in one playlist, replacing whatever was held for it.
    /// Rows per insert. SQLite allows 999 bound variables by default and
    /// each row binds two, so this stays comfortably inside it.
    private static let memberInsertChunk = 400

    public func saveMembers(ofPlaylist id: String, trackIds: [String], at when: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM playlistMember WHERE playlistId = ?", arguments: [id])
            // In chunks rather than one statement per song.
            let unique = Array(Set(trackIds))
            for chunk in stride(from: 0, to: unique.count, by: Self.memberInsertChunk) {
                let slice = unique[chunk..<min(chunk + Self.memberInsertChunk, unique.count)]
                let rows = Array(repeating: "(?, ?)", count: slice.count).joined(separator: ", ")
                var arguments: [any DatabaseValueConvertible] = []
                arguments.reserveCapacity(slice.count * 2)
                for trackId in slice {
                    arguments.append(id)
                    arguments.append(trackId)
                }
                try db.execute(
                    sql: "INSERT OR IGNORE INTO playlistMember (playlistId, trackId) VALUES \(rows)",
                    arguments: StatementArguments(arguments)
                )
            }
            try db.execute(
                sql: "UPDATE indexedPlaylist SET membersFetchedAt = ? WHERE id = ?",
                arguments: [when, id]
            )
        }
    }

    public func indexedPlaylists() throws -> [IndexedPlaylistRecord] {
        try database.read { db in try IndexedPlaylistRecord.fetchAll(db) }
    }

    // MARK: - Change outbox

    /// Adds a change, folding it into one already waiting where that is the truth: rating a song
    /// three times before the plane lands should reach the server as the rating you settled on, not
    /// as three writes.
    public func enqueueChange(_ entry: OutboxRecord) throws {
        try database.write { db in
            var entry = entry
            // The kind of thing matters as well as its id: server ids are opaque strings, and
            // nothing promises an album and a track cannot share one.
            if entry.kind != .play,
               let existing = try OutboxRecord
                .filter(
                    sql: "kind = ? AND itemId = ? AND mediaKind IS ?",
                    arguments: [entry.kind.rawValue, entry.itemId, entry.mediaKind]
                )
                .fetchOne(db)
            {
                entry.id = existing.id
            }
            try entry.save(db)
        }
    }

    /// Oldest first: the order they happened in is the order they are told in.
    public func pendingChanges(limit: Int = 500) throws -> [OutboxRecord] {
        try database.read { db in
            try OutboxRecord.order(sql: "id").limit(limit).fetchAll(db)
        }
    }

    public func pendingChangeCount() throws -> Int {
        try database.read { db in try OutboxRecord.fetchCount(db) }
    }

    public func removeChange(id: Int64) throws {
        _ = try database.write { db in try OutboxRecord.deleteOne(db, key: id) }
    }

    /// One waiting change as it is now, or nil once it has gone.
    public func change(id: Int64) throws -> OutboxRecord? {
        try database.read { db in try OutboxRecord.fetchOne(db, key: id) }
    }

    /// Removes a change only if it still says what the caller sent.
    @discardableResult
    public func removeChange(matching sent: OutboxRecord) throws -> Bool {
        guard let id = sent.id else { return false }
        return try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM outbox
                    WHERE id = ? AND kind = ? AND itemId = ?
                      AND rating IS ? AND flag IS ? AND mediaKind IS ?
                    """,
                arguments: [id, sent.kind.rawValue, sent.itemId, sent.rating, sent.flag, sent.mediaKind]
            )
            return db.changesCount > 0
        }
    }

    /// Drops whatever is waiting for one rating or heart, because a newer
    /// value for it has just reached the server. Never used for plays.
    @discardableResult
    public func discardChanges(
        kind: OutboxRecord.Kind,
        itemId: String,
        mediaKind: String?
    ) throws -> Int {
        guard kind != .play else { return 0 }
        return try database.write { db in
            try db.execute(
                sql: "DELETE FROM outbox WHERE kind = ? AND itemId = ? AND mediaKind IS ?",
                arguments: [kind.rawValue, itemId, mediaKind]
            )
            return db.changesCount
        }
    }

    public func recordChangeFailure(id: Int64, message: String) throws {
        try database.write { db in
            guard var entry = try OutboxRecord.fetchOne(db, key: id) else { return }
            entry.attempts += 1
            entry.lastError = message
            try entry.update(db)
        }
    }

    public func clearOutbox() throws {
        _ = try database.write { db in try OutboxRecord.deleteAll(db) }
    }

    // MARK: - Waveforms

    /// The bar levels drawn under a track, 0...1, or nil if none has been worked out yet.
    public func waveform(forTrack id: MediaID) throws -> [Float]? {
        try database.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT bars FROM waveform WHERE trackId = ?",
                arguments: [id.rawValue]
            ) else { return nil }
            return data.map { Float($0) / 255 }
        }
    }

    public func storeWaveform(_ bars: [Float], forTrack id: MediaID) throws {
        let data = Data(bars.map { UInt8(clamping: Int(($0.isFinite ? max(0, min(1, $0)) : 0) * 255)) })
        try database.write { db in
            try db.execute(
                sql: "INSERT INTO waveform (trackId, bars) VALUES (?, ?) ON CONFLICT(trackId) DO UPDATE SET bars = ?",
                arguments: [id.rawValue, data, data]
            )
        }
    }

    /// The review or description last fetched for an album, or the one the
    /// album's own row carries (Plex sends it with the listing). Nil when
    /// neither has been seen.
    public func albumNotes(forAlbum id: MediaID) throws -> String? {
        try database.read { db in
            if let stored = try String.fetchOne(
                db,
                sql: "SELECT notes FROM albumNotes WHERE albumId = ? AND notes != ''",
                arguments: [id.rawValue]
            ) { return stored }
            return try String.fetchOne(
                db,
                sql: "SELECT review FROM album WHERE id = ? AND TRIM(COALESCE(review, '')) != ''",
                arguments: [id.rawValue]
            )
        }
    }

    /// Keeps what a server said about an album. Empty text is not kept as
    /// notes: "no notes" is not worth remembering over a review that may
    /// arrive later — see `noteAlbumHasNoNotes(forAlbum:)`.
    public func storeAlbumNotes(_ notes: String, forAlbum id: MediaID) throws {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO albumNotes (albumId, notes, checkedAt) VALUES (?, ?, ?)
                    ON CONFLICT(albumId) DO UPDATE SET notes = excluded.notes, checkedAt = excluded.checkedAt
                    """,
                arguments: [id.rawValue, text, now]
            )
        }
    }

    /// Records that the server was asked and had nothing written, so the question is not put again
    /// until `checkedBefore` of `downloadedAlbumsLackingNotes` says it is worth another go.
    public func noteAlbumHasNoNotes(forAlbum id: MediaID) throws {
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO albumNotes (albumId, notes, checkedAt) VALUES (?, '', ?)
                    ON CONFLICT(albumId) DO UPDATE SET checkedAt = excluded.checkedAt
                    """,
                arguments: [id.rawValue, now]
            )
        }
    }

    /// Albums among `ids` with no review anywhere on the phone that have not
    /// been asked about since `checkedBefore`.
    public func albumsLackingNotes(_ ids: [MediaID], checkedBefore: Date) throws -> [MediaID] {
        let cutoff = checkedBefore.timeIntervalSince1970
        return try database.read { db in
            try ids.filter { id in
                try Self.lacksNotes(db, albumID: id.rawValue, checkedBefore: cutoff)
            }
        }
    }

    /// Albums that have a finished download here and no review kept, not asked
    /// about since `checkedBefore`.
    public func downloadedAlbumsLackingNotes(checkedBefore: Date) throws -> [MediaID] {
        let cutoff = checkedBefore.timeIntervalSince1970
        return try database.read { db in
            let candidates = try String.fetchAll(db, sql: """
                SELECT DISTINCT t.albumId FROM download d
                JOIN track t ON t.id = d.trackId
                WHERE d.state = 'done' AND t.albumId IS NOT NULL
                """)
            return try candidates
                .filter { try Self.lacksNotes(db, albumID: $0, checkedBefore: cutoff) }
                .map { MediaID(server: self.serverID, rawValue: $0) }
        }
    }

    private static func lacksNotes(_ db: Database, albumID: String, checkedBefore cutoff: Double) throws -> Bool {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(n.notes, '') AS notes, n.checkedAt AS checkedAt,
                   TRIM(COALESCE(a.review, '')) AS review
            FROM (SELECT ? AS id) q
            LEFT JOIN albumNotes n ON n.albumId = q.id
            LEFT JOIN album a ON a.id = q.id
            """, arguments: [albumID])
        guard let row else { return true }
        let notes: String = row["notes"]
        let review: String = row["review"]
        guard notes.isEmpty, review.isEmpty else { return false }
        guard let checked: Double = row["checkedAt"] else { return true }
        return checked < cutoff
    }

    /// Copies the current title, artists, album, cover and length of each downloaded song from the
    /// library onto its download row.
    @discardableResult
    public func refreshDownloadDetailsFromLibrary() throws -> Int {
        try database.write { db in
            try db.execute(sql: """
                UPDATE download SET
                    title = (SELECT t.title FROM track t WHERE t.id = download.trackId),
                    artistName = (SELECT t.artistName FROM track t WHERE t.id = download.trackId),
                    albumName = (SELECT t.albumName FROM track t WHERE t.id = download.trackId),
                    artworkId = COALESCE((SELECT t.artworkId FROM track t WHERE t.id = download.trackId), artworkId),
                    duration = COALESCE((SELECT t.duration FROM track t WHERE t.id = download.trackId), duration)
                WHERE EXISTS (
                    SELECT 1 FROM track t WHERE t.id = download.trackId AND (
                        t.title IS NOT download.title
                        OR t.artistName IS NOT download.artistName
                        OR t.albumName IS NOT download.albumName
                        OR (t.artworkId IS NOT NULL AND t.artworkId IS NOT download.artworkId)
                        OR (t.duration IS NOT NULL AND t.duration IS NOT download.duration)
                    )
                )
                """)
            return db.changesCount
        }
    }

    /// The covers of the albums the finished downloads belong to, as the
    /// library holds them now. The album's own cover can be a different
    /// picture from its songs', and it is the one an album page draws.
    public func artworkIDsOfDownloadedAlbums() throws -> Set<String> {
        try database.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT a.artworkId FROM album a
                JOIN track t ON t.albumId = a.id
                JOIN download d ON d.trackId = t.id
                WHERE d.state = 'done' AND a.artworkId IS NOT NULL
                """))
        }
    }

    private func id(of mediaID: MediaID) -> String {
        mediaID.rawValue
    }

    /// One album, without its tracklist — for the places that only need the
    /// sleeve and the name.
    public func album(id: MediaID) throws -> Album? {
        try database.read { db in
            try AlbumRecord.fetchOne(db, key: id.rawValue)?.domain(server: self.serverID)
        }
    }

    public func albumDetail(id: MediaID) throws -> AlbumDetail? {
        try database.read { db in
            guard let album = try AlbumRecord.fetchOne(db, key: id.rawValue) else { return nil }
            let tracks = try TrackRecord
                .filter(sql: "albumId = ?", arguments: [id.rawValue])
                .order(sql: "COALESCE(discNumber, 1), COALESCE(trackNumber, 0)")
                .fetchAll(db)
            return AlbumDetail(
                album: album.domain(server: self.serverID),
                tracks: tracks.map { $0.domain(server: self.serverID) }
            )
        }
    }

    public func track(id: MediaID) throws -> Track? {
        try database.read { db in
            try TrackRecord.fetchOne(db, key: id.rawValue)?.domain(server: self.serverID)
        }
    }

    /// Decade start years present in the library, newest first (e.g. 1990 covers 1990–1999).
    public func decades() throws -> [Int] {
        try database.read { db in
            try Int.fetchAll(db, sql: """
                SELECT DISTINCT (year / 10) * 10 AS decade
                FROM album WHERE year IS NOT NULL AND year > 0
                ORDER BY decade DESC
                """)
        }
    }

    /// Whether a decade radio has anything at all behind it.
    public func hasGenres() throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT EXISTS (SELECT 1 FROM track WHERE genre IS NOT NULL)"
            ) ?? false
        }
    }

    public func hasRadioDecades() throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1
                    FROM track LEFT JOIN album ON album.id = track.albumId
                    WHERE \(Self.settledEraSQL) > 0 AND \(Self.ratingFloorSQL)
                    LIMIT 1
                )
                """, arguments: [Self.favoriteRatingThreshold]) ?? false
        }
    }

    /// The decades the library's *music* comes from, which is not the same list.
    public func radioDecades() throws -> [Int] {
        // The rating floor is applied here as well as in the stations
        // themselves, so the picker cannot offer a decade whose every song
        // the station would then throw away.
        let settled: Set<Int> = try database.read { db in
            let years = try Int.fetchAll(db, sql: """
                SELECT DISTINCT \(Self.settledEraSQL) AS era
                FROM track LEFT JOIN album ON album.id = track.albumId
                WHERE \(Self.settledEraSQL) IS NOT NULL AND \(Self.settledEraSQL) > 0
                  AND \(Self.ratingFloorSQL)
                """, arguments: [Self.favoriteRatingThreshold])
            return Set(years.map { ($0 / 10) * 10 })
        }

        // The compilations SQL could not place, through the artist eras.
        let estimated: Set<Int> = try {
            let artists: [String] = try database.read { db in
                try String.fetchAll(db, sql: """
                    SELECT DISTINCT track.artistName
                    FROM track LEFT JOIN album ON album.id = track.albumId
                    WHERE album.isCollection = 1
                      AND \(Self.settledEraSQL) IS NULL
                      AND \(Self.ratingFloorSQL)
                      AND track.artistName IS NOT NULL AND track.artistName <> ''
                    """, arguments: [Self.favoriteRatingThreshold])
            }
            guard !artists.isEmpty else { return [] }
            let eras = try cachedActiveEraByArtist()
            return Set(artists.compactMap { eras[$0.lowercased()] }.map { ($0 / 10) * 10 })
        }()

        return settled.union(estimated).sorted(by: >)
    }

    public func genres() throws -> [Genre] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT genre,
                       COUNT(*) AS trackCount,
                       COUNT(DISTINCT albumId) AS albumCount,
                       COUNT(DISTINCT artistId) AS artistCount
                FROM track WHERE genre IS NOT NULL
                GROUP BY genre ORDER BY genre COLLATE NOCASE
                """).map { row in
                Genre(
                    name: row["genre"],
                    trackCount: row["trackCount"],
                    albumCount: row["albumCount"],
                    artistCount: row["artistCount"]
                )
            }
        }
    }

    // MARK: - Radio

    /// Songs for a station, in random order.
    public enum Station: Hashable, Sendable {
        /// The whole library.
        case everything
        /// Rated at or above `highlyRatedThreshold` — its own bar, held
        /// higher than the floor every station already applies.
        case highlyRated
        /// Never played, or barely.
        case deepCuts(playsAtMost: Int = 1)
        /// One decade or several: "the eighties" and "the eighties and
        /// nineties together" are the same station with a longer list.
        case decades([Int])
        case genres([String])
        /// One genre — under every name the library spells it — and one
        /// decade of it, or all of it where no decade is given.
        case genresInDecade(genres: [String], decade: Int?)
    }

    /// How long a record has to have been left alone to be worth meeting
    /// again. Half a year: long enough to have half forgotten it.
    static let rediscoverAfter: TimeInterval = 60 * 60 * 24 * 182

    /// Particular records, in the order asked for.
    public func albums(ids: [MediaID]) throws -> [Album] {
        guard !ids.isEmpty else { return [] }
        let wanted = ids.map(\.rawValue)
        let found = try database.read { db in
            try AlbumRecord
                .filter(keys: wanted)
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }
        }
        // Back into the order they were chosen in; anything since removed
        // from the library simply drops out.
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id.rawValue, $0) })
        return wanted.compactMap { byID[$0] }
    }

    /// A song's year: its own if it has one, otherwise its album's.
    private static let trackYear = "COALESCE(track.year, album.year)"

    /// A station's songs with no artist crowding the result.
    public func mixTracks(
        _ station: Station,
        limit: Int = 60,
        perArtist: Int = 2,
        downloadedOnly: Bool = false
    ) throws -> [Track] {
        let drawn = try stationTracks(
            station,
            limit: max(limit * 5, limit),
            downloadedOnly: downloadedOnly
        )
        var seen: [String: Int] = [:]
        var kept: [Track] = []
        for track in drawn {
            let artist = (track.artistName ?? track.id.rawValue).lowercased()
            guard seen[artist, default: 0] < perArtist else { continue }
            seen[artist, default: 0] += 1
            kept.append(track)
            if kept.count == limit { break }
        }
        // A library with fewer artists than the cap allows would come back
        // short; better a mix that repeats an artist than one that stops.
        if kept.count < limit {
            let already = Set(kept.map(\.id))
            kept += drawn.filter { !already.contains($0.id) }.prefix(limit - kept.count)
        }
        return kept
    }

    public func stationTracks(
        _ station: Station,
        limit: Int = 200,
        downloadedOnly: Bool = false
    ) throws -> [Track] {
        // Decades are their own thing: which decade a song belongs to is not
        // a column, and working it out needs the artist eras — see
        // `decadeTracks`.
        if case .decades(let decades) = station {
            return try decadeTracks(
                decades,
                limit: limit,
                downloadedOnly: downloadedOnly,
                extraClauses: [],
                extraArguments: []
            )
        }
        if case .genresInDecade(let names, let decade?) = station {
            guard !names.isEmpty else { return [] }
            let places = names.map { _ in "?" }.joined(separator: ", ")
            return try decadeTracks(
                [decade],
                limit: limit,
                downloadedOnly: downloadedOnly,
                extraClauses: ["COALESCE(track.genre, album.genre) IN (\(places))"],
                extraArguments: names
            )
        }

        var clauses: [String] = ["track.title IS NOT NULL", Self.ratingFloorSQL]
        var arguments: [any DatabaseValueConvertible] = [Self.favoriteRatingThreshold]

        switch station {
        case .everything:
            break
        case .highlyRated:
            clauses.append("track.rating >= ?")
            arguments.append(Self.highlyRatedThreshold)
        case .deepCuts(let playsAtMost):
            clauses.append("COALESCE(track.playCount, 0) <= ?")
            arguments.append(playsAtMost)
        case .decades:
            // Handled above.
            return []
        case .genres(let names):
            guard !names.isEmpty else { return [] }
            let places = names.map { _ in "?" }.joined(separator: ", ")
            // Same again: half a library's songs carry no genre of their own
            // and inherit the record's.
            clauses.append("COALESCE(track.genre, album.genre) IN (\(places))")
            arguments.append(contentsOf: names)
        case .genresInDecade(let names, _):
            // The decade-bearing case is handled above; this is the "all of
            // it" one, where the genre is the whole rule.
            guard !names.isEmpty else { return [] }
            let places = names.map { _ in "?" }.joined(separator: ", ")
            clauses.append("COALESCE(track.genre, album.genre) IN (\(places))")
            arguments.append(contentsOf: names)
        }

        if downloadedOnly {
            clauses.append("track.id IN (SELECT trackId FROM download WHERE state = 'done')")
        }

        // Joined so a track can borrow its record's year and genre.
        let sql = """
            SELECT track.* FROM track
            LEFT JOIN album ON album.id = track.albumId
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY RANDOM()
            LIMIT ?
            """
        arguments.append(limit)

        return try database.read { db in
            try TrackRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// Any tracks at all, drawn at random — no rating, genre or download filter of any kind.
    public func randomTracks(limit: Int) throws -> [Track] {
        try database.read { db in
            try TrackRecord
                .fetchAll(
                    db, sql: "SELECT * FROM track WHERE title IS NOT NULL ORDER BY RANDOM() LIMIT ?",
                    arguments: [limit])
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// No song rated below the favourites line, ever, in any mix.
    private static let ratingFloorSQL = "(track.rating IS NULL OR track.rating >= ?)"

    /// What the Artist & Album Mixer offers before anything has been typed or picked: records
    /// played lately, and the artists behind them.
    public func mixerRecentlyPlayed(limit: Int) throws -> (artists: [Artist], albums: [Album]) {
        try database.read { db in
            let albums = try AlbumRecord
                .filter(sql: "playedAt IS NOT NULL")
                .order(sql: "playedAt DESC")
                .limit(limit)
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }

            // The artists behind those same records, in the order the records
            // were played, so the two halves of the grid agree with each
            // other rather than reading as two unrelated lists.
            var seen: Set<String> = []
            let artistIDs = albums.compactMap(\.artistID).filter { seen.insert($0.rawValue).inserted }
            let byID = Dictionary(
                grouping: try ArtistRecord.fetchAll(db, keys: artistIDs.map(\.rawValue)),
                by: \.id
            )
            let artists = artistIDs.compactMap { byID[$0.rawValue]?.first }
                .map { $0.domain(server: self.serverID) }
                .filter { !CompilationHeuristics.isVariousArtists($0.name) }
            return (artists, albums)
        }
    }

    /// Artists and albums that keep company with a selection — what the grid offers once something
    /// has been picked and nothing is being typed.
    public func mixerNeighbours(
        artistIDs: [MediaID],
        albumIDs: [MediaID],
        limit: Int
    ) throws -> (artists: [Artist], albums: [Album]) {
        guard !artistIDs.isEmpty || !albumIDs.isEmpty else { return ([], []) }
        let artistKeys = artistIDs.map(\.rawValue)
        let albumKeys = albumIDs.map(\.rawValue)

        return try database.read { db in
            // What the selection sounds like, as far as the library records
            // it: every genre named by an album the selection reaches.
            var genreClauses: [String] = []
            var genreArguments: [any DatabaseValueConvertible] = []
            if !artistKeys.isEmpty {
                genreClauses.append("artistId IN (\(Self.places(artistKeys.count)))")
                genreArguments.append(contentsOf: artistKeys)
            }
            if !albumKeys.isEmpty {
                genreClauses.append("id IN (\(Self.places(albumKeys.count)))")
                genreArguments.append(contentsOf: albumKeys)
            }
            let genres = try String.fetchAll(db, sql: """
                SELECT DISTINCT genre FROM album
                WHERE genre IS NOT NULL AND genre != ''
                  AND (\(genreClauses.joined(separator: " OR ")))
                """, arguments: StatementArguments(genreArguments))
            guard !genres.isEmpty else { return ([], []) }

            // Excluded both ways: an album already picked, and any album by
            // an artist already picked — otherwise picking an artist fills
            // the grid with that artist's own records.
            var exclusions = ["album.genre IN (\(Self.places(genres.count)))"]
            var arguments: [any DatabaseValueConvertible] = genres
            if !artistKeys.isEmpty {
                exclusions.append("(album.artistId IS NULL OR album.artistId NOT IN (\(Self.places(artistKeys.count))))")
                arguments.append(contentsOf: artistKeys)
            }
            if !albumKeys.isEmpty {
                exclusions.append("album.id NOT IN (\(Self.places(albumKeys.count)))")
                arguments.append(contentsOf: albumKeys)
            }
            let shared = exclusions.joined(separator: " AND ")

            // Best regarded first, then most played: the neighbours worth
            // offering are the ones somebody would actually want added.
            let albums = try AlbumRecord.fetchAll(db, sql: """
                SELECT album.* FROM album
                WHERE \(shared)
                ORDER BY COALESCE(album.rating, 0) DESC, COALESCE(album.playCount, 0) DESC,
                         album.name COLLATE NOCASE
                LIMIT ?
                """, arguments: StatementArguments(arguments + [limit]))
                .map { $0.domain(server: self.serverID) }

            // "Various Artists" is not somebody to suggest: it is what a server writes where an
            // album has no one artist, so offering it means offering every compilation in the
            // library at once.
            let artists = try ArtistRecord.fetchAll(db, sql: """
                SELECT artist.* FROM artist
                JOIN album ON album.artistId = artist.id
                WHERE \(shared)
                GROUP BY artist.id
                ORDER BY COUNT(*) DESC, artist.name COLLATE NOCASE
                LIMIT ?
                """, arguments: StatementArguments(arguments + [limit]))
                .map { $0.domain(server: self.serverID) }
                .filter { !CompilationHeuristics.isVariousArtists($0.name) }

            return (artists, albums)
        }
    }

    private static func places(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    /// Every song the Artist & Album Mixer's selection reaches, once each.
    public func mixerTracks(
        artistIDs: [MediaID],
        albumIDs: [MediaID],
        downloadedOnly: Bool = false
    ) throws -> [Track] {
        guard !artistIDs.isEmpty || !albumIDs.isEmpty else { return [] }

        var selections: [String] = []
        var arguments: [any DatabaseValueConvertible] = []

        func clauses(_ extra: String, _ extraArguments: [any DatabaseValueConvertible]) {
            var all = ["track.title IS NOT NULL", Self.ratingFloorSQL, extra]
            if downloadedOnly {
                all.append("track.\(Self.downloadedTrackClause)")
            }
            selections.append("""
                SELECT track.* FROM track
                JOIN album ON album.id = track.albumId
                WHERE \(all.joined(separator: " AND "))
                """)
            arguments.append(Self.favoriteRatingThreshold)
            arguments.append(contentsOf: extraArguments)
        }

        if !artistIDs.isEmpty {
            let places = artistIDs.map { _ in "?" }.joined(separator: ", ")
            clauses("album.artistId IN (\(places))", artistIDs.map(\.rawValue))
        }
        if !albumIDs.isEmpty {
            let places = albumIDs.map { _ in "?" }.joined(separator: ", ")
            clauses("track.albumId IN (\(places))", albumIDs.map(\.rawValue))
        }

        let sql = selections.joined(separator: "\nUNION\n")
        return try database.read { db in
            try TrackRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// Songs from one or more decades, judged by when the music was made.
    private func decadeTracks(
        _ decades: [Int],
        limit: Int,
        downloadedOnly: Bool,
        extraClauses: [String],
        extraArguments: [any DatabaseValueConvertible]
    ) throws -> [Track] {
        guard !decades.isEmpty else { return [] }

        var clauses: [String] = ["track.title IS NOT NULL", Self.ratingFloorSQL]
        var arguments: [any DatabaseValueConvertible] = [Self.favoriteRatingThreshold]
        clauses.append(contentsOf: extraClauses)
        arguments.append(contentsOf: extraArguments)

        let spans = decades.map { _ in "(\(Self.settledEraSQL) >= ? AND \(Self.settledEraSQL) < ?)" }
        var decadeArguments: [any DatabaseValueConvertible] = []
        for decade in decades {
            decadeArguments.append(decade)
            decadeArguments.append(decade + 10)
        }
        clauses.append("""
            (
                (\(spans.joined(separator: " OR ")))
                OR (album.isCollection = 1 AND \(Self.settledEraSQL) IS NULL)
            )
            """)
        arguments.append(contentsOf: decadeArguments)

        if downloadedOnly {
            clauses.append("track.id IN (SELECT trackId FROM download WHERE state = 'done')")
        }

        // Drawn wider than asked for, because the compilation rows in the set have not been judged
        // yet and most of them will belong to some other decade.
        let draw = min(max(limit * 4, 200), 2000)
        let sql = """
            SELECT
                track.*,
                album.year AS albumYear,
                album.releaseDate AS albumReleaseDate,
                album.isCollection AS albumIsCollection
            FROM track
            LEFT JOIN album ON album.id = track.albumId
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY RANDOM()
            LIMIT ?
            """
        arguments.append(draw)

        let eras = try cachedActiveEraByArtist()
        let wanted = Set(decades.map { ($0 / 10) * 10 })

        return try database.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            var kept: [Track] = []
            for row in rows where kept.count < limit {
                let record = try TrackRecord(row: row)
                let albumYear: Int? = row["albumYear"]
                let albumReleaseDate: Date? = row["albumReleaseDate"]
                let isCompilation: Bool = row["albumIsCollection"] ?? false
                let artist = (record.artistName ?? "").lowercased()

                let classification = TrackEra.resolve(
                    TrackEra.Signals(
                        trackOriginalYear: record.originalYear,
                        albumOriginalYear: albumReleaseDate.map(Self.year(of:)),
                        albumYear: albumYear,
                        trackYear: record.year,
                        isCompilation: isCompilation,
                        artistEstimate: eras[artist]
                    )
                )

                Self.log.debug(
                    """
                    era \(record.title, privacy: .public): \
                    year=\(classification.year ?? -1, privacy: .public) \
                    source=\(classification.source?.rawValue ?? "none", privacy: .public) \
                    lowConfidence=\(classification.isLowConfidence, privacy: .public)
                    """
                )

                // A compilation that fell back to its own pressing year has told us only that
                // nobody knows — and a decade radio that believed it would fill up with exactly the
                // records this whole pipeline exists to keep out.
                guard !classification.isLowConfidence,
                      let decade = classification.decade,
                      wanted.contains(decade)
                else { continue }
                kept.append(record.domain(server: self.serverID))
            }
            return kept
        }
    }

    /// The era a song settles on from its own columns alone — everything `TrackEra` can decide
    /// without knowing anything about the artist.
    private static let settledEraSQL = """
        COALESCE(
            CASE
                WHEN track.originalYear IS NOT NULL
                     AND NOT (COALESCE(album.isCollection, 0) = 1
                              AND track.originalYear = album.year)
                THEN track.originalYear
            END,
            CASE
                WHEN CAST(strftime('%Y', album.releaseDate) AS INTEGER) IS NOT NULL
                     AND album.year IS NOT NULL
                     AND CAST(strftime('%Y', album.releaseDate) AS INTEGER) <> album.year
                THEN CAST(strftime('%Y', album.releaseDate) AS INTEGER)
                WHEN CAST(strftime('%Y', album.releaseDate) AS INTEGER) IS NOT NULL
                     AND album.year IS NULL
                     AND COALESCE(album.isCollection, 0) = 0
                THEN CAST(strftime('%Y', album.releaseDate) AS INTEGER)
            END,
            CASE WHEN COALESCE(album.isCollection, 0) = 0
                 THEN COALESCE(track.year, album.year)
            END
        )
        """

    // MARK: - Made For You

    /// A mix with the sleeves and the names it is drawn with.
    public func dressed(_ mix: MadeForYou.Mix) -> MadeForYou.Mix {
        var dressed = mix
        switch mix.kind {
        case .artist(let name, _, _):
            // Who else the mix will be.
            dressed.artists = company(for: name)
            // A mix about somebody wears their face.
            dressed.artwork = (try? artistArtwork(named: name)) ?? mix.artwork
        case .tag(_, let decade, let members):
            // A genre is a corner of a library rather than a record, so it
            // is drawn as several sleeves the way a playlist is. The single
            // one is kept as well, for anywhere too small to lay four out.
            let several = (try? artworksForMix(genres: members, decade: decade)) ?? []
            dressed.artworks = several
            dressed.artwork = several.first
                ?? (try? artworkForMix(genres: members, decade: decade))
            dressed.artists = (try? topArtists(genres: members, decade: decade)) ?? []
        }
        return dressed
    }

    /// The artists that belong beside a seed, biggest first.
    public func company(for artist: String, most: Int = 3) -> [String] {
        guard let tags = try? genreTagsByArtist(), !tags.isEmpty else { return [] }
        let seed = GenreAffinity.tokens(of: tags[artist.lowercased()] ?? [])
        guard !seed.isEmpty else { return [] }
        guard let counts = try? artistSongCounts() else { return [] }
        let eras = (try? cachedActiveEraByArtist()) ?? [:]
        let seedEra = eras[artist.lowercased()]
        var out: [String] = []
        for (name, _) in counts where out.count < most {
            let key = name.lowercased()
            guard key != artist.lowercased(), let theirs = tags[key] else { continue }
            guard EraAffinity.belongs(candidate: eras[key], withSeed: seedEra) else { continue }
            if GenreAffinity.belongs(candidate: GenreAffinity.tokens(of: theirs), withSeed: seed) {
                out.append(name)
            }
        }
        return out
    }

    // MARK: - Editors' Choice

    /// Records a reviewer thought highly of, and wrote about.
    public func criticallyAcclaimedAlbums(atLeast score: Double) throws -> [Album] {
        try database.read { db in
            try AlbumRecord
                .filter(sql: """
                    criticRating IS NOT NULL AND criticRating >= ?
                    AND review IS NOT NULL
                    AND LENGTH(TRIM(review)) >= ?
                    """, arguments: [score, EditorsChoice.shortestUsableReview])
                .order(sql: "id")
                .fetchAll(db)
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// Every artist's own best-rated albums, best first, capped — the raw material `Spotlight`
    /// ranks artists from.
    public func topRatedAlbumsByArtist(
        usingCriticRating: Bool, capped: Int = 5
    ) throws -> [String: [Album]] {
        let column = usingCriticRating ? "criticRating" : "rating"
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH ranked AS (
                    SELECT album.*, ROW_NUMBER() OVER (
                        PARTITION BY artistName ORDER BY \(column) DESC, year ASC
                    ) AS rn
                    FROM album
                    WHERE artistName IS NOT NULL AND artistName <> ''
                        AND \(column) IS NOT NULL
                )
                SELECT * FROM ranked WHERE rn <= ?
                """,
                arguments: [capped]
            )
            var out: [String: [Album]] = [:]
            for row in rows {
                let record = try AlbumRecord(row: row)
                guard let artist = record.artistName, !CompilationHeuristics.isVariousArtists(artist)
                else { continue }
                out[artist.lowercased(), default: []].append(record.domain(server: self.serverID))
            }
            return out
        }
    }

    /// What a given day looks like against the rest of the year.
    public struct ReleaseDay: Sendable {
        public let matches: Int
        public let averagePerDay: Double

        /// Whether the date is a filing convention rather than a fact.
        public var isPlaceholder: Bool {
            matches >= 50 && Double(matches) > averagePerDay * 10
        }
    }

    /// Counts a day against the average, in one pass.
    public func releaseDay(month: Int, day: Int) throws -> ReleaseDay {
        let stamp = String(format: "%02d-%02d", month, day)
        return try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    SUM(CASE WHEN strftime('%m-%d', releaseDate) = ? THEN 1 ELSE 0 END) AS matches,
                    COUNT(*) AS total,
                    COUNT(DISTINCT strftime('%m-%d', releaseDate)) AS days
                FROM album
                WHERE releaseDate IS NOT NULL
                """, arguments: [stamp])
            let matches = row?["matches"] as Int? ?? 0
            let total = row?["total"] as Int? ?? 0
            let days = row?["days"] as Int? ?? 0
            return ReleaseDay(
                matches: matches,
                averagePerDay: days > 0 ? Double(total) / Double(days) : 0
            )
        }
    }

    /// Records released on a given day of the year, whatever the year.
    public func albumsReleased(month: Int, day: Int, limit: Int = 20) throws -> [Album] {
        let stamp = String(format: "%02d-%02d", month, day)
        return try database.read { db in
            try AlbumRecord.fetchAll(db, sql: """
                SELECT * FROM album
                WHERE releaseDate IS NOT NULL
                  AND strftime('%m-%d', releaseDate) = ?
                ORDER BY
                    CASE
                        WHEN isCompilation = 1 THEN 2
                        WHEN artistName = 'Various Artists' COLLATE NOCASE THEN 2
                        -- Wrapped in commas so this matches the whole word:
                        -- the column is a comma-joined list, and without it
                        -- "compilation" would also match nothing while
                        -- "album" matched "album,compilation".
                        WHEN ',' || releaseTypes || ',' LIKE '%,compilation,%' THEN 2
                        WHEN ',' || releaseTypes || ',' LIKE '%,album,%' THEN 0
                        ELSE 1
                    END,
                    releaseDate DESC
                LIMIT ?
                """, arguments: [stamp, limit])
                .map { $0.domain(server: self.serverID) }
        }
    }

    // MARK: Filters

    /// The songs a filter finds, newest first where it can tell.
    public func tracks(
        matching filter: LibraryFilter,
        order: SongOrder? = nil,
        direction: SortDirection = .forward,
        limit: Int = 200,
        downloadedOnly: Bool = false,
        randomOrder: Bool = false
    ) throws -> [Track] {
        guard filter.subject == .songs else { return [] }
        let compiled = filter.compile()
        var clauses = [compiled.sql]
        var arguments = compiled.arguments
        if downloadedOnly {
            clauses.append("track.id IN (SELECT trackId FROM download WHERE state = 'done')")
        }
        // Without an order asked for, the record's: a shelf of songs reads as
        // a list of songs from records. A screen that is sorted asks for its
        // own, so filtering a list does not quietly resort it.
        var orderBy = "album.addedAt DESC, track.discNumber, track.trackNumber"
        if let order {
            let shape = Self.sql(for: order, direction: direction)
            if let extra = shape.where { clauses.append(extra) }
            orderBy = shape.orderBy
        }
        // For a caller drawing a candidate pool to rank itself, not to show as a list —
        // `album.addedAt DESC` would hand back the single newest record's tracks first, every time,
        // and a ranking that is stable on ties keeps them there.
        if randomOrder { orderBy = "RANDOM()" }
        let sql = """
            SELECT track.* FROM track
            LEFT JOIN album ON album.id = track.albumId
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(orderBy)
            LIMIT ?
            """
        arguments.append(limit)
        return try database.read { db in
            try TrackRecord
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { $0.domain(server: self.serverID) }
        }
    }

    /// The albums a filter finds.
    public func albums(
        matching filter: LibraryFilter,
        order: AlbumFilter? = nil,
        direction: SortDirection = .forward,
        within ids: [MediaID]? = nil,
        limit: Int = 200,
        downloadedOnly: Bool = false
    ) throws -> [Album] {
        guard filter.subject == .albums else { return [] }
        // An empty restriction is "none of them", not "no restriction" — the
        // caller asking about nothing should get nothing back rather than
        // the library.
        if let ids, ids.isEmpty { return [] }
        let compiled = filter.compile()
        var clauses = [compiled.sql]
        var arguments = compiled.arguments
        if let ids {
            clauses.append("album.id IN (\(Self.places(ids.count)))")
            arguments.append(contentsOf: ids.map(\.rawValue))
        }
        if downloadedOnly {
            clauses.append("""
                album.id IN (
                    SELECT track.albumId FROM track
                    JOIN download ON download.trackId = track.id AND download.state = 'done'
                )
                """)
        }
        var orderBy = "album.addedAt DESC NULLS LAST, \(Self.albumByNameKey), album.id"
        if let order {
            let shape = Self.sql(for: order, direction: direction)
            if let extra = shape.where {
                clauses.append(extra)
                arguments += shape.arguments
            }
            orderBy = shape.orderBy
        }
        // Argument order is load-bearing: the compiled filter's placeholders come first because its
        // clause was appended first, the order's own placeholders next, and the limit last —
        // matching the order the clauses and the trailing `LIMIT ?` appear…
        arguments.append(limit)
        let sql = """
            SELECT \(Self.albumColumns) FROM album
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY \(orderBy)
            LIMIT ?
            """
        return try database.read { db in
            try Self.wholeAlbums(db, sql: sql, arguments: arguments, server: self.serverID)
        }
    }

    /// How many things a filter finds, for the running count under a filter while it is being
    /// built.
    public func count(
        matching filter: LibraryFilter,
        downloadedOnly: Bool = false,
        within ids: [MediaID]? = nil,
        page: AlbumFilter? = nil
    ) throws -> Int {
        let compiled = filter.compile()
        var clauses = [compiled.sql]
        var arguments = compiled.arguments
        let sql: String
        switch filter.subject {
        case .songs:
            if downloadedOnly {
                clauses.append("track.id IN (SELECT trackId FROM download WHERE state = 'done')")
            }
            sql = """
                SELECT COUNT(*) FROM track
                LEFT JOIN album ON album.id = track.albumId
                WHERE \(clauses.joined(separator: " AND "))
                """
        case .albums:
            if let ids {
                // An empty restriction is "none of them", as in `albums(matching:)`.
                if ids.isEmpty { return 0 }
                clauses.append("album.id IN (\(Self.places(ids.count)))")
                arguments.append(contentsOf: ids.map(\.rawValue))
            }
            if downloadedOnly {
                clauses.append("""
                    album.id IN (
                        SELECT track.albumId FROM track
                        JOIN download ON download.trackId = track.id AND download.state = 'done'
                    )
                    """)
            }
            if let page, let extra = Self.sql(for: page, direction: .forward).where {
                clauses.append(extra)
                arguments += Self.sql(for: page, direction: .forward).arguments
            }
            sql = """
                SELECT COUNT(*) FROM album
                WHERE \(clauses.joined(separator: " AND "))
                """
        case .artists:
            // An artist is not a file, but one with nothing on the phone is
            // not on the list offline.
            if downloadedOnly { clauses.append(Self.downloadedArtistClause) }
            sql = """
                SELECT COUNT(*) FROM artist
                WHERE \(clauses.joined(separator: " AND "))
                """
        }
        return try database.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        }
    }

    /// The artists a filter finds, by name.
    public func artists(
        matching filter: LibraryFilter,
        order: ArtistOrder = .alphabetical,
        direction: SortDirection = .forward,
        limit: Int? = nil,
        downloadedOnly: Bool = false
    ) throws -> [Artist] {
        guard filter.subject == .artists else { return [] }
        let compiled = filter.compile()
        let arguments = compiled.arguments + (limit.map { [$0] } ?? [])
        let downloaded = downloadedOnly ? " AND \(Self.downloadedArtistClause)" : ""
        let sql = """
            SELECT \(Self.artistColumns) FROM artist
            WHERE (\(compiled.sql))\(downloaded)
            ORDER BY \(Self.artistOrderBy(order, direction: direction))
            \(limit == nil ? "" : "LIMIT ?")
            """
        return try database.read { db in
            try Self.wholeArtists(db, sql: sql, arguments: arguments, server: self.serverID)
        }
    }

    /// How many songs a station would draw on, so an empty one can be left
    /// off the shelf rather than offered and found silent.
    public func stationSize(_ station: Station, downloadedOnly: Bool = false) throws -> Int {
        try stationTracks(station, limit: 1, downloadedOnly: downloadedOnly).count
    }

    // MARK: - Search

    /// The most rows of one kind the search reads before ranking them.
    static let searchPoolSize = 3000

    /// Substring search across artists, albums, and tracks.
    public func search(_ query: String, limit: Int, downloadedOnly: Bool = false) throws -> SearchResults {
        // Folded the same way the index is, so an apostrophe or a full stop
        // in either one cannot keep them apart.
        let needle = Self.folded(query)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return SearchResults() }

        // Terms, with the short ones grouped back into the runs they were typed in.
        var phrases: [String] = []
        var stragglers: [String] = []
        var run: [String] = []

        func closeRun() {
            guard !run.isEmpty else { return }
            let spaced = run.joined(separator: " ")
            if spaced.count >= 3 {
                // An acronym is written both ways and typed both ways, so both are asked for:
                // "r.e.m." should find a band tagged R.E.M.
                let closed = run.joined()
                phrases.append(closed.count >= 3 && closed != spaced
                    ? "(\(Self.quoted(spaced)) OR \(Self.quoted(closed)))"
                    : Self.quoted(spaced))
            } else {
                stragglers.append(spaced)
            }
            run = []
        }

        for term in needle.split(whereSeparator: \.isWhitespace).map(String.init) {
            if term.count >= 3 {
                closeRun()
                phrases.append(Self.quoted(term))
            } else {
                run.append(term)
            }
        }
        closeRun()

        // What each kind may match, cut down to the downloaded ones *inside*
        // the query when offline. Filtered after the LIMIT instead, most of
        // a big library's downloaded matches were never in the pool at all.
        func downloadedItems(_ kind: String) -> String {
            switch kind {
            case "track":
                return "SELECT trackId FROM download WHERE state = 'done'"
            case "album":
                return """
                    SELECT DISTINCT track.albumId FROM track
                    JOIN download ON download.trackId = track.id
                    WHERE download.state = 'done' AND track.albumId IS NOT NULL
                    """
            default:
                return """
                    SELECT DISTINCT track.artistId FROM track
                    JOIN download ON download.trackId = track.id
                    WHERE download.state = 'done' AND track.artistId IS NOT NULL
                    """
            }
        }

        // One pool per kind.
        let poolSize = max(limit * 8, Self.searchPoolSize)

        return try database.read { db in
            func pool(_ kind: String) throws -> [Row] {
                var conditions: [String] = []
                var arguments: [any DatabaseValueConvertible] = []
                // With no phrase there is nothing for the trigram index to match: one or two
                // characters and nothing else.
                if !phrases.isEmpty {
                    conditions.append("search MATCH ?")
                    arguments.append(phrases.joined(separator: " AND "))
                }
                // Either column will do — a term is "in" a row wherever it
                // falls, the same as the trigram match.
                for straggler in stragglers {
                    conditions.append("(name LIKE ? ESCAPE \'\\\' OR artist LIKE ? ESCAPE \'\\\')")
                    let pattern = "%\(Self.escapedForLike(straggler))%"
                    arguments.append(pattern)
                    arguments.append(pattern)
                }
                conditions.append("kind = ?")
                arguments.append(kind)
                if downloadedOnly {
                    // Offline: a result you cannot open is worse than no result.
                    conditions.append("itemId IN (\(downloadedItems(kind)))")
                }
                arguments.append(poolSize)
                return try Row.fetchAll(
                    db,
                    sql: """
                        SELECT kind, itemId, name, artist FROM search
                        WHERE \(conditions.joined(separator: " AND ")) LIMIT ?
                        """,
                    arguments: StatementArguments(arguments)
                )
            }
            let rows = try pool("artist") + pool("album") + pool("track")

            var ranked: [String: [(id: String, score: Int)]] = [:]
            for row in rows {
                let kind: String = row["kind"]
                let itemId: String = row["itemId"]
                let name: String = row["name"]
                let by: String = row["artist"]
                ranked[kind, default: []].append(
                    (itemId, Self.rank(name: name, by: by, needle: needle))
                )
            }

            func ids(_ kind: String) -> [String] {
                (ranked[kind] ?? [])
                    .sorted { ($0.score, $0.id) < ($1.score, $1.id) }
                    .prefix(limit)
                    .map(\.id)
            }

            // `fetchAll(keys:)` returns rows in arbitrary order, so the rank
            // order is reapplied afterwards.
            func inRankOrder<T>(_ values: [T], ids: [String], id: (T) -> String) -> [T] {
                let position = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                return values.sorted { (position[id($0)] ?? 0) < (position[id($1)] ?? 0) }
            }

            let artistIDs = ids("artist")
            let albumIDs = ids("album")
            let trackIDs = ids("track")

            let artists = try ArtistRecord.fetchAll(db, keys: artistIDs)
            let albums = try AlbumRecord.fetchAll(db, keys: albumIDs)
            let tracks = try TrackRecord.fetchAll(db, keys: trackIDs)

            return SearchResults(
                artists: inRankOrder(
                    artists.map { $0.domain(server: self.serverID) },
                    ids: artistIDs,
                    id: { $0.id.rawValue }
                ),
                albums: inRankOrder(
                    albums.map { $0.domain(server: self.serverID) },
                    ids: albumIDs,
                    id: { $0.id.rawValue }
                ),
                tracks: inRankOrder(
                    tracks.map { $0.domain(server: self.serverID) },
                    ids: trackIDs,
                    id: { $0.id.rawValue }
                )
            )
        }
    }

    /// Lower is better: an exact name beats a leading match, which beats a word starting with the
    /// term, which beats a match inside a word.
    static func rank(name: String, by: String, needle: String) -> Int {
        let inName = matchScore(content: name.lowercased(), needle: needle)
        if inName < 4 { return inName }
        let inBy = matchScore(content: by.lowercased(), needle: needle)
        if inBy < 4 { return 10 + inBy }
        return 20
    }

    static func matchScore(content: String, needle: String) -> Int {
        guard let range = content.range(of: needle) else { return 4 }
        if content == needle { return 0 }
        if range.lowerBound == content.startIndex { return 1 }
        let preceding = content[content.index(before: range.lowerBound)]
        return preceding.isWhitespace || preceding.isPunctuation ? 2 : 3
    }

    /// A term as the trigram index takes it: one literal string, quotes of
    /// its own dropped rather than escaped, because a quote inside a phrase
    /// ends it and FTS5 answers a malformed query by throwing.
    private static func quoted(_ term: String) -> String {
        "\"\(term.replacingOccurrences(of: "\"", with: ""))\""
    }

    private static func escapedForLike(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Local state mirrors
    // Applied immediately after a successful server write so the UI reflects
    // changes without waiting for the next full sync.

    private static func favoriteTable(_ kind: MediaKind) -> String? {
        switch kind {
        case .artist: "artist"
        case .album: "album"
        case .track: "track"
        case .playlist, .genre: nil
        }
    }

    public func mirrorFavorite(_ favorite: Bool, for id: MediaID, kind: MediaKind) throws {
        guard let table = Self.favoriteTable(kind) else { return }
        localWrites.withLock { $0.noteFavorite(favorite, id: id.rawValue, table: table) }
        try database.write { db in
            try db.execute(
                sql: "UPDATE \(table) SET isFavorite = ? WHERE id = ?",
                arguments: [favorite, id.rawValue]
            )
        }
    }

    public func mirrorRating(_ rating: StarRating?, for id: MediaID) throws {
        localWrites.withLock { $0.noteRating(rating?.value, id: id.rawValue) }
        try database.write { db in
            for table in ["track", "album", "artist"] {
                try db.execute(
                    sql: "UPDATE \(table) SET rating = ? WHERE id = ?",
                    arguments: [rating?.value, id.rawValue]
                )
            }
        }
    }

    /// What the index shows for an item's rating, for putting it back if the
    /// server turns a change down.
    public func mirroredRating(for id: MediaID) throws -> StarRating? {
        try database.read { db in
            for table in ["track", "album", "artist"] {
                if let value = try Double.fetchOne(
                    db, sql: "SELECT rating FROM \(table) WHERE id = ?", arguments: [id.rawValue]
                ) {
                    return StarRating(value)
                }
            }
            return nil
        }
    }

    public func mirroredFavorite(for id: MediaID, kind: MediaKind) throws -> Bool {
        guard let table = Self.favoriteTable(kind) else { return false }
        return try database.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT isFavorite FROM \(table) WHERE id = ?", arguments: [id.rawValue]
            ) ?? false
        }
    }

    /// Puts a rating back after the server refused it — but only while the index still shows the
    /// value that was refused.
    @discardableResult
    public func revertRating(
        to previous: StarRating?,
        for id: MediaID,
        ifShowing refused: StarRating?
    ) throws -> Bool {
        let reverted = try database.write { db -> Bool in
            var changed = false
            for table in ["track", "album", "artist"] {
                try db.execute(
                    sql: "UPDATE \(table) SET rating = ? WHERE id = ? AND rating IS ?",
                    arguments: [previous?.value, id.rawValue, refused?.value]
                )
                if db.changesCount > 0 { changed = true }
            }
            return changed
        }
        if reverted { localWrites.withLock { $0.noteRating(previous?.value, id: id.rawValue) } }
        return reverted
    }

    @discardableResult
    public func revertFavorite(
        to previous: Bool,
        for id: MediaID,
        kind: MediaKind,
        ifShowing refused: Bool
    ) throws -> Bool {
        guard let table = Self.favoriteTable(kind) else { return false }
        let reverted = try database.write { db -> Bool in
            try db.execute(
                sql: "UPDATE \(table) SET isFavorite = ? WHERE id = ? AND isFavorite = ?",
                arguments: [previous, id.rawValue, refused]
            )
            return db.changesCount > 0
        }
        if reverted { localWrites.withLock { $0.noteFavorite(previous, id: id.rawValue, table: table) } }
        return reverted
    }

    public func mirrorPlay(trackID: MediaID, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE track SET playCount = COALESCE(playCount, 0) + 1, playedAt = ? WHERE id = ?",
                arguments: [date, trackID.rawValue]
            )
            try db.execute(sql: """
                UPDATE album SET playedAt = ?, playCount = COALESCE(playCount, 0) + 1
                WHERE id = (SELECT albumId FROM track WHERE id = ?)
                """, arguments: [date, trackID.rawValue])
        }
    }
}

/// Ratings and hearts given on this device since the running sync began.
struct LocalWrites: Sendable {
    enum Write: Sendable {
        case rating(Double?, id: String)
        case favorite(Bool, id: String, table: String)

        func apply(_ db: Database) throws {
            switch self {
            case .rating(let value, let id):
                for table in ["track", "album", "artist"] {
                    try db.execute(
                        sql: "UPDATE \(table) SET rating = ? WHERE id = ?",
                        arguments: [value, id]
                    )
                }
            case .favorite(let flag, let id, let table):
                try db.execute(
                    sql: "UPDATE \(table) SET isFavorite = ? WHERE id = ?",
                    arguments: [flag, id]
                )
            }
        }
    }

    var syncStartedAt: Date?
    private var writes: [String: (write: Write, at: Date)] = [:]

    mutating func noteRating(_ value: Double?, id: String) {
        writes["rating|\(id)"] = (.rating(value, id: id), Date())
    }

    mutating func noteFavorite(_ flag: Bool, id: String, table: String) {
        writes["favorite|\(table)|\(id)"] = (.favorite(flag, id: id, table: table), Date())
    }

    /// Only what happened while a sync was running; with none running there
    /// is nothing for a walk to have overwritten.
    func sinceSyncBegan() -> [Write] {
        guard let started = syncStartedAt else { return [] }
        return writes.values.filter { $0.at >= started }.map(\.write)
    }

    mutating func syncEnded() {
        syncStartedAt = nil
        writes.removeAll()
    }
}

