import Foundation
import Testing
@testable import PleviDomain

/// The case this was written for, and the ways it could go wrong.
@Suite("Whether two artists' eras belong in the same mix")
struct EraAffinityTests {
    @Test("The reported case would not be made again")
    func theReportedCase() {
        #expect(!EraAffinity.belongs(candidate: 1961, withSeed: 2019))
        #expect(!EraAffinity.belongs(candidate: 2019, withSeed: 1961))
    }

    @Test("A generation apart still counts as company")
    func withinTolerance() {
        // Taylor Swift's own median (2008–2023 originals) and Miley Cyrus's
        // (2009–2023) — contemporaries, not the same year.
        #expect(EraAffinity.belongs(candidate: 2011, withSeed: 2019))
        #expect(EraAffinity.belongs(candidate: 2019, withSeed: 2011))
    }

    @Test("Exactly at the edge is still close enough")
    func theBoundaryItself() {
        #expect(EraAffinity.belongs(candidate: 2000, withSeed: 2000 + EraAffinity.toleranceYears))
    }

    @Test("One year past the edge is not")
    func justOverTheBoundary() {
        #expect(!EraAffinity.belongs(candidate: 2000, withSeed: 2001 + EraAffinity.toleranceYears))
    }

    /// An artist with nothing dated and uncompiled of their own is not evidence of the wrong era —
    /// it is no evidence at all, and ruling them out on it would fall hardest on exactly the thin
    /// catalogues a mix most needs a fallback for.
    @Test("Missing data is kept, on either side")
    func missingDataIsKept() {
        #expect(EraAffinity.belongs(candidate: nil, withSeed: 1970))
        #expect(EraAffinity.belongs(candidate: 1970, withSeed: nil))
        #expect(EraAffinity.belongs(candidate: nil, withSeed: nil))
    }
}
