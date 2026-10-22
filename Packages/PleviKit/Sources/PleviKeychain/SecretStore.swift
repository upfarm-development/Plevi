import Foundation
import Synchronization

/// Addresses one secret. `account` is conventionally
/// "<server-uuid>/<field>" (e.g. "…/password", "…/apiKey",
/// "…/header.CF-Access-Client-Secret", "…/clientIdentity").
public struct SecretKey: Hashable, Sendable {
    public var service: String
    public var account: String

    public init(service: String = SecretKey.defaultService, account: String) {
        self.service = service
        self.account = account
    }

    public static let defaultService = BundleIdentity.app
}

/// The identifier keychain items are filed under: the phone app's own, which
/// the watch declares as its companion. Read from the running bundle so the
/// source names no developer account; it is set in the build configuration.
enum BundleIdentity {
    static let app: String = {
        let bundle = Bundle.main
        return (bundle.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String)
            ?? bundle.bundleIdentifier
            ?? "plevi"
    }()
}

/// Storage for server credentials and other secrets. Secrets exist only here —
/// never in config files, logs, or URLs beyond what a request itself requires.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> Data?
    func setSecret(_ data: Data, for key: SecretKey) throws
    func removeSecret(for key: SecretKey) throws
    /// Removes every secret whose account starts with `prefix` — used to wipe
    /// all credentials for a server when it is deleted.
    func removeSecrets(accountPrefix prefix: String) throws
}

public extension SecretStore {
    func secretString(for key: SecretKey) throws -> String? {
        try secret(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func setSecretString(_ value: String, for key: SecretKey) throws {
        try setSecret(Data(value.utf8), for: key)
    }
}

/// Test/preview double. Not persistent.
public final class InMemorySecretStore: SecretStore, Sendable {
    private let storage = Mutex<[SecretKey: Data]>([:])

    public init() {}

    public func secret(for key: SecretKey) throws -> Data? {
        storage.withLock { $0[key] }
    }

    public func setSecret(_ data: Data, for key: SecretKey) throws {
        storage.withLock { $0[key] = data }
    }

    public func removeSecret(for key: SecretKey) throws {
        storage.withLock { $0[key] = nil }
    }

    public func removeSecrets(accountPrefix prefix: String) throws {
        storage.withLock { dict in
            for key in dict.keys where key.account.hasPrefix(prefix) {
                dict[key] = nil
            }
        }
    }
}
