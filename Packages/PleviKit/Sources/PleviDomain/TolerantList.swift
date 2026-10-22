import Foundation

/// A stored JSON array that survives having elements it cannot read.
public struct TolerantList<Element: Codable & Sendable>: Sendable {
    public var items: [Element]
    /// The elements that did not decode, each as its own JSON document.
    public var leftovers: [Data]

    public init(items: [Element] = [], leftovers: [Data] = []) {
        self.items = items
        self.leftovers = leftovers
    }

    /// `nil` when `data` is not a JSON array at all. The caller should keep
    /// it rather than treat the list as empty.
    public static func decode(_ data: Data, using decoder: JSONDecoder = JSONDecoder()) -> TolerantList? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var list = TolerantList()
        for element in parsed {
            guard JSONSerialization.isValidJSONObject([element]),
                  let raw = try? JSONSerialization.data(withJSONObject: element, options: [.fragmentsAllowed])
            else { continue }
            if let item = try? decoder.decode(Element.self, from: raw) {
                list.items.append(item)
            } else {
                list.leftovers.append(raw)
            }
        }
        return list
    }

    /// The array to store: what decoded, re-encoded, followed by what did
    /// not, exactly as it was found.
    public func encoded(using encoder: JSONEncoder = JSONEncoder()) -> Data? {
        var objects: [Any] = []
        for item in items {
            guard let raw = try? encoder.encode(item),
                  let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
            else { return nil }
            objects.append(object)
        }
        for raw in leftovers {
            guard let object = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed])
            else { continue }
            objects.append(object)
        }
        return try? JSONSerialization.data(withJSONObject: objects)
    }
}
