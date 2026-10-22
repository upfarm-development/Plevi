import Foundation
import Testing
@testable import PleviDomain

@Suite("An endless carousel's place in its run")
struct LoopingCarouselTests {
    @Test("The middle copy is the one with as much either side")
    func middleIsTheMiddle() {
        #expect(LoopingCarousel.middle(of: 4) == 16)
        #expect(LoopingCarousel.middle(of: 10) == 40)
        #expect(LoopingCarousel.middle(of: 0) == 0)
    }

    @Test("A slot names a card whichever copy of it is showing")
    func slotNamesACard() {
        #expect(LoopingCarousel.centredIndex(at: 16, of: 4) == 0)
        #expect(LoopingCarousel.centredIndex(at: 18, of: 4) == 2)
        #expect(LoopingCarousel.centredIndex(at: nil, of: 4) == 0)
        #expect(LoopingCarousel.centredIndex(at: 5, of: 0) == 0)
    }

    /// The bug, written down: a shelf that fills itself in one card at a
    /// time used to change which card was centred on every arrival, without
    /// the carousel moving.
    @Test("A card arriving does not change which card is showing")
    func growingKeepsTheCard() {
        // Sitting on the first card of four.
        var slot: Int? = LoopingCarousel.middle(of: 4)
        #expect(LoopingCarousel.centredIndex(at: slot, of: 4) == 0)

        // Three more arrive. Left alone, slot 16 in a run of seven would be
        // card 2 — the dance. It is moved instead, and stays card 0.
        #expect(LoopingCarousel.centredIndex(at: slot, of: 7) == 2)
        slot = LoopingCarousel.slot(keeping: slot, wasShowing: 4, nowShowing: 7, grew: true)
        #expect(LoopingCarousel.centredIndex(at: slot, of: 7) == 0)

        // And three more.
        slot = LoopingCarousel.slot(keeping: slot, wasShowing: 7, nowShowing: 10, grew: true)
        #expect(LoopingCarousel.centredIndex(at: slot, of: 10) == 0)
    }

    @Test("A card arriving while you are looking at the third one keeps the third one")
    func growingKeepsWhereverYouWere() {
        let slot = LoopingCarousel.middle(of: 4) + 2
        #expect(LoopingCarousel.centredIndex(at: slot, of: 4) == 2)
        let moved = LoopingCarousel.slot(keeping: slot, wasShowing: 4, nowShowing: 9, grew: true)
        #expect(LoopingCarousel.centredIndex(at: moved, of: 9) == 2)
    }

    @Test("A different set of records starts at its own beginning")
    func adifferentSetStartsOver() {
        let slot = LoopingCarousel.middle(of: 6) + 3
        let moved = LoopingCarousel.slot(keeping: slot, wasShowing: 6, nowShowing: 6, grew: false)
        #expect(LoopingCarousel.centredIndex(at: moved, of: 6) == 0)
        #expect(moved == LoopingCarousel.middle(of: 6))
    }

    @Test("Emptied, there is no slot at all")
    func emptyHasNoSlot() {
        #expect(LoopingCarousel.slot(keeping: 16, wasShowing: 4, nowShowing: 0, grew: false) == nil)
    }

    @Test("A first arrival on an empty shelf lands in the middle")
    func theFirstCardsLandInTheMiddle() {
        #expect(
            LoopingCarousel.slot(keeping: nil, wasShowing: 0, nowShowing: 4, grew: true)
                == LoopingCarousel.middle(of: 4)
        )
    }

    @Test("Always somewhere the run actually reaches")
    func staysInsideTheRun() {
        for old in 1...12 {
            for new in old...20 {
                for current in [0, old, LoopingCarousel.middle(of: old), old * 8 + 3] {
                    let moved = LoopingCarousel.slot(
                        keeping: current, wasShowing: old, nowShowing: new, grew: true
                    )
                    let slot = try! #require(moved)
                    #expect(slot >= 0)
                    #expect(slot < new * LoopingCarousel.copies, "\(old)->\(new) at \(current)")
                }
            }
        }
    }
}
