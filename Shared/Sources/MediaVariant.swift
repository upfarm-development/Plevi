import Foundation

/// Which version of a track a file holds.
enum MediaVariant: Hashable, Sendable {
    case original
    case converted(codec: String, kbps: Int?)

    /// Goes in the file name, so the store can read a directory and know what
    /// it is holding without opening anything.
    var tag: String {
        switch self {
        case .original:
            return "orig"
        case .converted(let codec, let kbps):
            let rate = kbps.map(String.init) ?? "auto"
            return "c-\(codec.lowercased())-\(rate)"
        }
    }

    var isOriginal: Bool { self == .original }

    /// Back from the tag, so a download can say what it actually holds.
    init?(tag: String) {
        if tag == "orig" {
            self = .original
            return
        }
        let parts = tag.split(separator: "-", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "c" else { return nil }
        self = .converted(codec: parts[1], kbps: parts[2] == "auto" ? nil : Int(parts[2]))
    }
}
