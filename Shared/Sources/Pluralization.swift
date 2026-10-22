import Foundation

extension Int {
    /// "1 song" / "4 songs".
    func counted(_ singular: String, _ plural: String? = nil) -> String {
        let plural = plural ?? singular + "s"
        return "\(self) \(self == 1 ? singular : plural)"
    }
}
