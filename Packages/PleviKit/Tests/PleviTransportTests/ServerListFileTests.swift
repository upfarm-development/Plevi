import Foundation
import Testing
import PleviDomain
@testable import PleviTransport

@Suite("Reading the servers file without losing servers")
struct ServerListFileTests {
    private func server(_ name: String) -> ServerConfig {
        ServerConfig(name: name, addresses: .remote(URL(string: "https://\(name).example.com")!))
    }

    /// A file as a newer build would have written it: `names` in order, the
    /// ones in `unknown` with a kind this build has never heard of.
    private func file(_ configs: [ServerConfig], unknown: Set<String> = [], active: ServerID?) throws -> Data {
        let encoded = try ServerListFile.encode(servers: configs, activeServerID: active)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var entries = try #require(object["servers"] as? [[String: Any]])
        for index in entries.indices where unknown.contains(entries[index]["name"] as? String ?? "") {
            entries[index]["kind"] = "jellyfin"
        }
        object["servers"] = entries
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test func aFileThisBuildCanReadRoundTrips() throws {
        let a = server("a"), b = server("b")
        let data = try file([a, b], active: b.id)
        let contents = try #require(ServerListFile.decode(data))
        #expect(contents.servers == [a, b])
        #expect(contents.activeServerID == b.id)
        #expect(contents.skipped == 0)
    }

    @Test func oneServerThisBuildCannotReadDoesNotCostTheOthers() throws {
        let a = server("a"), newer = server("newer"), c = server("c")
        let data = try file([a, newer, c], unknown: ["newer"], active: c.id)
        let contents = try #require(ServerListFile.decode(data))
        #expect(contents.servers.map(\.name) == ["a", "c"])
        #expect(contents.skipped == 1)
        #expect(contents.activeServerID == c.id)
    }

    @Test func aDamagedFileIsNotAnEmptyList() {
        #expect(ServerListFile.decode(Data("{ not json".utf8)) == nil)
        #expect(ServerListFile.decode(Data("{\"other\": 1}".utf8)) == nil)
        #expect(ServerListFile.decode(Data()) == nil)
    }

    @Test func aRealEmptyListIsStillEmpty() throws {
        let data = try ServerListFile.encode(servers: [], activeServerID: nil)
        let contents = try #require(ServerListFile.decode(data))
        #expect(contents.servers.isEmpty && contents.skipped == 0)
    }

    @Test func theFirstCopyKeptIsTheOneThatStays() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "servers-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "servers.json")

        try Data("first".utf8).write(to: url)
        let copy = try #require(ServerListFile.keepCopy(of: url))
        try Data("second".utf8).write(to: url)
        _ = ServerListFile.keepCopy(of: url)
        #expect(try Data(contentsOf: copy) == Data("first".utf8))
        // The original is untouched by keeping a copy.
        #expect(try Data(contentsOf: url) == Data("second".utf8))
    }
}
