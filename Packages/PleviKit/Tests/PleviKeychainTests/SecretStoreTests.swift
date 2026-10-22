import Foundation
import Testing
@testable import PleviKeychain

@Suite struct InMemorySecretStoreTests {
    @Test func roundTripsSecrets() throws {
        let store = InMemorySecretStore()
        let key = SecretKey(account: "server-1/password")
        try store.setSecretString("hunter2", for: key)
        #expect(try store.secretString(for: key) == "hunter2")
        try store.removeSecret(for: key)
        #expect(try store.secret(for: key) == nil)
    }

    @Test func overwritesExistingSecret() throws {
        let store = InMemorySecretStore()
        let key = SecretKey(account: "server-1/apiKey")
        try store.setSecretString("old", for: key)
        try store.setSecretString("new", for: key)
        #expect(try store.secretString(for: key) == "new")
    }

    @Test func prefixRemovalWipesOnlyThatServer() throws {
        let store = InMemorySecretStore()
        try store.setSecretString("a", for: SecretKey(account: "server-1/password"))
        try store.setSecretString("b", for: SecretKey(account: "server-1/header.CF-Access-Client-Secret"))
        try store.setSecretString("c", for: SecretKey(account: "server-2/password"))
        try store.removeSecrets(accountPrefix: "server-1/")
        #expect(try store.secret(for: SecretKey(account: "server-1/password")) == nil)
        #expect(try store.secret(for: SecretKey(account: "server-1/header.CF-Access-Client-Secret")) == nil)
        #expect(try store.secretString(for: SecretKey(account: "server-2/password")) == "c")
    }
}
