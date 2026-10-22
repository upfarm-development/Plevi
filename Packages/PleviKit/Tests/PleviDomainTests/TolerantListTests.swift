import Foundation
import Testing
@testable import PleviDomain

@Suite("A stored list that keeps what it cannot read")
struct TolerantListTests {
    private struct Shelf: Codable, Equatable, Sendable {
        var name: String
        var limit: Int
    }

    @Test("Readable elements decode and unreadable ones come back raw")
    func splits() throws {
        let json = Data(#"[{"name":"A","limit":1},{"name":"B","future":true},{"name":"C","limit":3}]"#.utf8)
        let list = try #require(TolerantList<Shelf>.decode(json))
        #expect(list.items == [Shelf(name: "A", limit: 1), Shelf(name: "C", limit: 3)])
        #expect(list.leftovers.count == 1)
    }

    @Test("Saving writes the unreadable element back untouched")
    func roundTrips() throws {
        let json = Data(#"[{"name":"A","limit":1},{"name":"B","future":[1,2]}]"#.utf8)
        var list = try #require(TolerantList<Shelf>.decode(json))
        list.items.append(Shelf(name: "New", limit: 9))
        let saved = try #require(list.encoded())
        let object = try #require(JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        #expect(object.count == 3)
        #expect(object.contains { ($0["name"] as? String) == "B" && ($0["future"] as? [Int]) == [1, 2] })
        // And what is readable is still readable.
        let again = try #require(TolerantList<Shelf>.decode(saved))
        #expect(again.items.map(\.name) == ["A", "New"])
        #expect(again.leftovers.count == 1)
    }

    @Test("Something that is not an array is not an empty list")
    func notAnArray() {
        #expect(TolerantList<Shelf>.decode(Data("{}".utf8)) == nil)
        #expect(TolerantList<Shelf>.decode(Data("garbage".utf8)) == nil)
        #expect(TolerantList<Shelf>.decode(Data("[]".utf8))?.items.isEmpty == true)
    }
}
