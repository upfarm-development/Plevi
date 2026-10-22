import Foundation

/// The settings snapshot as a document: what goes into it from a `UserDefaults`, and what a restore
/// writes back.
public enum BackupDocument {
    public struct Keys: Sendable {
        /// Settings that travel as they are.
        public var carried: [String]
        /// Home's arrangement, kept per library under `<key>.<library uuid>`.
        public var perLibrary: [String]
        /// The play log's key among `perLibrary`: its entries name the
        /// library they were recorded in.
        public var playLog: String

        public init(carried: [String], perLibrary: [String], playLog: String) {
            self.carried = carried
            self.perLibrary = perLibrary
            self.playLog = playLog
        }
    }

    public static let currentVersion = 1

    /// Where a restored install keeps the arrangements of libraries it has
    /// not connected yet, by `LibraryFingerprint`.
    public static let pendingKey = "settings.backup.pendingLibraries"

    // MARK: Reading a document

    private static func parse(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    /// The `values` a stored document was carrying.
    public static func storedValues(_ data: Data) -> [String: Any]? {
        parse(data)?["values"] as? [String: Any]
    }

    /// The `libraries` a stored document was carrying.
    public static func storedLibraries(_ data: Data) -> [String: [String: Any]]? {
        parse(data)?["libraries"] as? [String: [String: Any]]
    }

    // MARK: Building one

    /// The settings themselves, apart from the wrapping: a document also
    /// carries a timestamp, which makes two otherwise-identical documents
    /// compare unequal every time one is built.
    public static func values(of defaults: UserDefaults, keys: Keys, libraryScope: String?) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in keys.carried {
            if let value = defaults.object(forKey: key) { values[key] = value }
        }
        // The arrangement, stripped of the library it was arranged in.
        if let scope = libraryScope {
            for (base, value) in arrangement(of: defaults, keys: keys, scope: scope) { values[base] = value }
        }
        return values
    }

    private static func arrangement(of defaults: UserDefaults, keys: Keys, scope: String) -> [String: Any] {
        var found: [String: Any] = [:]
        for base in keys.perLibrary {
            if let value = defaults.object(forKey: "\(base).\(scope)") { found[base] = value }
        }
        return found
    }

    /// Every library's arrangement, by fingerprint: what the stored document already held for the
    /// others, with the open library's own put over it.
    public static func libraries(
        of defaults: UserDefaults,
        keys: Keys,
        libraryScope: String?,
        libraryFingerprint: String?,
        stored: Data?
    ) -> [String: [String: Any]] {
        let previous = stored.flatMap(storedLibraries) ?? [:]
        let active = libraryScope.map { arrangement(of: defaults, keys: keys, scope: $0) } ?? [:]
        return LibraryBackup.merged(stored: previous, active: libraryFingerprint, values: active)
    }

    /// Everything worth keeping, as one document.
    public static func snapshot(
        of defaults: UserDefaults,
        keys: Keys,
        libraryScope: String?,
        libraryFingerprint: String?,
        stored: Data?,
        deviceName: String,
        now: Date = Date()
    ) -> Data? {
        let values = values(of: defaults, keys: keys, libraryScope: libraryScope)
        guard !values.isEmpty else { return nil }

        func encode(libraries: [String: [String: Any]]) -> Data? {
            var document: [String: Any] = [
                "version": currentVersion,
                "writtenAt": now,
                // Named so a restore can say where it came from. On a family
                // iCloud account this is the only thing that tells somebody
                // they are about to inherit another person's settings.
                "deviceName": deviceName,
                // The open library's arrangement under its unscoped names, as
                // it always was: a build that does not know `libraries` reads
                // this and nothing else.
                "values": values,
            ]
            if !libraries.isEmpty { document["libraries"] = libraries }
            return try? PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
        }

        let all = libraries(
            of: defaults, keys: keys, libraryScope: libraryScope,
            libraryFingerprint: libraryFingerprint, stored: stored
        )
        guard let data = encode(libraries: all) else { return nil }
        guard LibraryBackup.shouldDropOtherLibraries(documentSize: data.count),
              let libraryFingerprint, let own = all[libraryFingerprint]
        else { return data }
        return encode(libraries: [libraryFingerprint: own])
    }

    // MARK: Restoring one

    /// Writes a snapshot into `defaults`, returning how many settings landed.
    @discardableResult
    public static func apply(
        _ data: Data,
        to defaults: UserDefaults,
        keys: Keys,
        libraryScope: String? = nil,
        libraryFingerprint: String? = nil
    ) -> Int {
        guard let document = parse(data),
              let version = document["version"] as? Int, version <= currentVersion,
              let values = document["values"] as? [String: Any]
        else { return 0 }

        let allowed = Set(keys.carried)
        var landed = 0
        for (key, value) in values where allowed.contains(key) {
            defaults.set(value, forKey: key)
            landed += 1
        }

        let libraries = document["libraries"] as? [String: [String: Any]] ?? [:]
        let perLibrary = Set(keys.perLibrary)
        if !libraries.isEmpty, libraryScope == nil || libraryFingerprint != nil {
            var pending = pendingLibraries(in: defaults)
            for (fingerprint, theirs) in libraries {
                let own = theirs.filter { perLibrary.contains($0.key) }
                if let scope = libraryScope, fingerprint == libraryFingerprint {
                    landed += write(own, scope: scope, keys: keys, into: defaults)
                    pending.removeValue(forKey: fingerprint)
                } else {
                    pending[fingerprint] = own
                }
            }
            setPending(pending, in: defaults)
            if libraryScope != nil { removeUnscopedCopies(keys: keys, in: defaults) }
        } else {
            // A document from before the libraries were told apart, or an
            // install that cannot say which library is open: it holds one
            // library's arrangement and cannot say whose.
            let own = values.filter { perLibrary.contains($0.key) }
            if let scope = libraryScope {
                landed += write(own, scope: scope, keys: keys, into: defaults)
                removeUnscopedCopies(keys: keys, in: defaults)
            } else {
                for (key, value) in own {
                    defaults.set(value, forKey: key)
                    landed += 1
                }
            }
        }
        return landed
    }

    /// Writes one library's arrangement under the keys the app reads it
    /// from, replacing what is there.
    private static func write(_ values: [String: Any], scope: String, keys: Keys, into defaults: UserDefaults) -> Int {
        let scoped = LibraryBackup.scopedValues(
            of: values, scope: scope,
            rebasingPlayLogTo: UUID(uuidString: scope).map { ServerID(rawValue: $0) },
            playLogKey: keys.playLog
        )
        for (key, value) in scoped { defaults.set(value, forKey: key) }
        return scoped.count
    }

    /// Unscoped arrangement keys exist only to be handed to the first library
    /// that connects. Once a library is open they would be handed to the next
    /// one, which is not whose they are.
    private static func removeUnscopedCopies(keys: Keys, in defaults: UserDefaults) {
        for base in keys.perLibrary { defaults.removeObject(forKey: base) }
    }

    public static func pendingLibraries(in defaults: UserDefaults) -> [String: [String: Any]] {
        defaults.dictionary(forKey: pendingKey) as? [String: [String: Any]] ?? [:]
    }

    private static func setPending(_ pending: [String: [String: Any]], in defaults: UserDefaults) {
        if pending.isEmpty { defaults.removeObject(forKey: pendingKey) } else { defaults.set(pending, forKey: pendingKey) }
    }

    /// Hands a library the arrangement a restore set aside for it.
    public static func adoptPending(
        into defaults: UserDefaults,
        keys: Keys,
        scope: String,
        fingerprint: String?
    ) {
        guard let fingerprint else { return }
        var pending = pendingLibraries(in: defaults)
        guard let mine = pending[fingerprint] else { return }
        let scoped = LibraryBackup.scopedValues(
            of: mine, scope: scope,
            rebasingPlayLogTo: UUID(uuidString: scope).map { ServerID(rawValue: $0) },
            playLogKey: keys.playLog
        )
        for (key, value) in scoped where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        pending.removeValue(forKey: fingerprint)
        setPending(pending, in: defaults)
    }
}
