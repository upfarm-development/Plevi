import Foundation
import Testing
@testable import PleviDomain

/// What filing a whole library into A–Z buckets costs.
@Suite("Filing a library into letters")
struct AlphabetIndexScaleTests {
    private struct Row {
        let title: String
    }

    /// Titles shaped like a real library: mostly ASCII, a scattering of
    /// Nordic letters and other scripts that take the careful path.
    private func rows(_ count: Int) -> [Row] {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let awkward = ["Ærøskøbing", "Østen", "Åsa", "Ölandsvisan", "日本の歌", "123 Go", "  spaced"]
        return (0..<count).map { i in
            if i % 40 == 0 {
                return Row(title: awkward[i % awkward.count])
            }
            let letter = letters[i % letters.count]
            return Row(title: "\(letter)ong number \(i)")
        }
    }

    @Test("Filing sixty thousand songs is quick enough to do on a background thread")
    func atLibraryScale() {
        let values = rows(61_287)
        let started = Date()
        let groups = AlphabetIndex.group(values) { $0.title }
        let elapsed = Date().timeIntervalSince(started)
        #expect(groups.reduce(0) { $0 + $1.values.count } == 61_287)
        print("GROUPSCALE 61,287 songs filed in \(String(format: "%.1f", elapsed * 1000))ms")
        // Not a target, a tripwire: this is a single linear pass and should
        // stay one.
        #expect(elapsed < 3.0, "took \(String(format: "%.2f", elapsed))s")
    }
}
