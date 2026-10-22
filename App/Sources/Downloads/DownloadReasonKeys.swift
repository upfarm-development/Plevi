import Foundation

extension String {
    /// The rest of the string when it starts with `prefix`, otherwise nil.
    /// Reason keys are "album:1234" and the like; this reads the id back out.
    func dropPrefixIfPresent(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}
