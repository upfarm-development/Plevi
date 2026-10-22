import Foundation
import Testing
@testable import PleviDomain

@Suite("What a DJ is forbidden to repeat")
struct DJRepeatWindowTests {
    private let server = ServerID()
    private func id(_ raw: String) -> MediaID { MediaID(server: server, rawValue: raw) }

    private func track(_ raw: String, artist: String = "Some Artist", title: String? = nil) -> Track {
        Track(id: id(raw), title: title ?? raw, artistName: artist)
    }

    @Test("Nothing is excluded to start")
    func emptyToStart() {
        let window = DJRepeatWindow()
        #expect(!window.excludes(id("t1")))
        #expect(window.isEmpty)
    }

    @Test("A played track is excluded")
    func playedIsExcluded() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1"))
        #expect(window.excludes(id("t1")))
        #expect(!window.excludes(id("t2")))
    }

    @Test("Everything currently queued is excluded, not just what a DJ put there")
    func queuedIsExcluded() {
        var window = DJRepeatWindow()
        window.setQueued([track("t1"), track("t2")])
        #expect(window.excludes(id("t1")))
        #expect(window.excludes(id("t2")))
        #expect(!window.excludes(id("t3")))
    }

    @Test("The queued set is replaced wholesale on every call, not accumulated")
    func queuedReplacesRatherThanAccumulates() {
        var window = DJRepeatWindow()
        window.setQueued([track("t1")])
        window.setQueued([track("t2")])
        #expect(!window.excludes(id("t1")))
        #expect(window.excludes(id("t2")))
    }

    @Test("The oldest play ages out once the window is full")
    func agesOutOldest() {
        var window = DJRepeatWindow(historyCapacity: 3)
        window.recordPlayed(track("t1"))
        window.recordPlayed(track("t2"))
        window.recordPlayed(track("t3"))
        #expect(window.excludes(id("t1")))
        window.recordPlayed(track("t4"))
        #expect(!window.excludes(id("t1")), "the fourth play should have pushed the first out")
        #expect(window.excludes(id("t2")))
        #expect(window.excludes(id("t3")))
        #expect(window.excludes(id("t4")))
    }

    @Test("Hearing the same track again moves it to the front rather than counting twice")
    func replayMovesToFront() {
        var window = DJRepeatWindow(historyCapacity: 2)
        window.recordPlayed(track("t1"))
        window.recordPlayed(track("t2"))
        window.recordPlayed(track("t1"))
        // If the replay had been appended as a second, distinct entry, the
        // window (capacity 2) would have pushed "t2" out already.
        #expect(window.excludes(id("t2")), "a replay should not have shrunk how far back the window reaches")
    }

    @Test("A capacity of zero excludes nothing from history, only from the live queue")
    func zeroCapacityDisablesHistory() {
        var window = DJRepeatWindow(historyCapacity: 0)
        window.recordPlayed(track("t1"))
        #expect(!window.excludes(id("t1")))
    }

    @Test("excludedIDs is the union of both halves")
    func excludedIDsUnion() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1"))
        window.setQueued([track("t2")])
        #expect(window.excludedIDs == [id("t1"), id("t2")])
    }

    // MARK: The recording itself, across catalog ids

    /// The bug, as a test: the same recording — "Barbie Girl" by Aqua — filed under three different
    /// ids, one per compilation it appears on in the library.
    @Test("A played recording is excluded under a different catalog id too")
    func playedRecordingExcludedAcrossIDs() {
        var window = DJRepeatWindow()
        let onFirstCompilation = track("now-39", artist: "Aqua", title: "Barbie Girl")
        let onSecondCompilation = track("now-20", artist: "Aqua", title: "Barbie Girl")
        window.recordPlayed(onFirstCompilation)
        // Different catalog id — the id-based check does not catch it.
        #expect(!window.excludes(onSecondCompilation.id))
        // The song-identity check does.
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: onSecondCompilation)))
    }

    @Test("A queued recording is excluded under a different catalog id too")
    func queuedRecordingExcludedAcrossIDs() {
        var window = DJRepeatWindow()
        window.setQueued([track("now-39", artist: "Aqua", title: "Barbie Girl")])
        let elsewhere = track("now-20", artist: "Aqua", title: "Barbie Girl")
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: elsewhere)))
    }

    @Test("The song-identity match is case- and whitespace-insensitive")
    func songKeyIsNormalised() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Aqua", title: "Barbie Girl"))
        let differentlyCased = track("t2", artist: "  AQUA ", title: "barbie girl ")
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: differentlyCased)))
    }

    /// Both of these were caught on a real device: the song queued directly
    /// behind itself, because a compilation credited it with a different
    /// join word than the album did.
    @Test("A re-credited collaboration is the same recording")
    func creditVariationsAreOneSong() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("album", artist: "Coldplay & Selena Gomez", title: "Let Somebody Go"))
        let onACompilation = track("now111", artist: "Coldplay x Selena Gomez", title: "Let Somebody Go")
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: onACompilation)))

        var second = DJRepeatWindow()
        second.recordPlayed(track("now76", artist: "Justin Bieber feat. Ludacris", title: "Baby"))
        let onTheAlbum = track("myworld", artist: "Justin Bieber & Ludacris", title: "Baby")
        #expect(second.excludesSong(DJRepeatWindow.songKey(for: onTheAlbum)))
    }

    /// The one this was written for, off a real device.
    @Test("A duet credited the other way round is the same recording")
    func reversedCreditIsOneSong() {
        var window = DJRepeatWindow()
        window.recordPlayed(
            track("bryson", artist: "Peabo Bryson & Céline Dion", title: "Beauty and the Beast")
        )
        let hers = track("dion", artist: "Céline Dion with Peabo Bryson", title: "Beauty and the Beast")
        #expect(window.excludes(hers.id) == false, "two compilations are two catalog ids")
        #expect(
            window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: hers)),
            "the same performance, named in the other order, is not a second song"
        )
    }

    /// The case a simpler fix would have broken, with nothing to catch it.
    @Test("A guest spelled out in the credit does not make a second song")
    func spelledOutGuestIsOneSong() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("bare", artist: "Kidswaste", title: "Wild"))
        let spelledOut = track("full", artist: "Kidswaste & Khai", title: "Wild")
        #expect(window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: spelledOut)))
    }

    @Test("Two people who never played together are not one recording")
    func sameTitleDifferentPeople() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Peabo Bryson & Céline Dion", title: "Beauty and the Beast"))
        let stranger = track("t2", artist: "Angela Lansbury", title: "Beauty and the Beast")
        #expect(!window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: stranger)))
    }

    @Test("Every name in a credit is found, however it was punctuated")
    func namesAreSplitAndSorted() {
        #expect(
            DJRepeatWindow.creditedNames(of: "Peabo Bryson & Céline Dion")
                == DJRepeatWindow.creditedNames(of: "Céline Dion with Peabo Bryson")
        )
        #expect(DJRepeatWindow.creditedNames(of: "A feat. B") == ["a", "b"])
        #expect(DJRepeatWindow.creditedNames(of: "Solo") == ["solo"])
        #expect(DJRepeatWindow.creditedNames(of: "   ").isEmpty)
    }

    /// The window holds a set of keys per recording now rather than one
    /// string, so ageing has to drop a key only when no entry left still
    /// answers to it.
    @Test("Ageing out one recording does not blind the window to another")
    func ageingKeepsWhatIsStillHeld() {
        var window = DJRepeatWindow(historyCapacity: 2)
        window.recordPlayed(track("a", artist: "Kidswaste", title: "Wild"))
        window.recordPlayed(track("b", artist: "Aqua", title: "Barbie Girl"))
        // A third pushes the first out.
        window.recordPlayed(track("c", artist: "Coldplay", title: "Yellow"))
        #expect(!window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: track("a2", artist: "Kidswaste", title: "Wild"))))
        #expect(window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: track("b2", artist: "Aqua", title: "Barbie Girl"))))
        #expect(window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: track("c2", artist: "Coldplay", title: "Yellow"))))
    }

    /// The leak the first draft of the two-key window had, and which none of the tests above would
    /// have caught.
    @Test("Ageing out a re-credited recording forgets every spelling of it")
    func mergedEntryDoesNotOrphanItsKeys() {
        var window = DJRepeatWindow(historyCapacity: 3)
        let his = track("bryson", artist: "Peabo Bryson & Céline Dion", title: "Beauty and the Beast")
        let hers = track("dion", artist: "Céline Dion with Peabo Bryson", title: "Beauty and the Beast")
        window.recordPlayed(his)
        window.recordPlayed(hers)
        // One recording, one entry, and no key left over from the merge.
        #expect(
            window.excludedSongKeys.count == DJRepeatWindow.songKeys(for: hers).count,
            "the merge left \(window.excludedSongKeys.count) keys behind for one recording"
        )
        // Push it out.
        for n in 0..<3 { window.recordPlayed(track("filler\(n)", artist: "Someone \(n)", title: "Song \(n)")) }
        #expect(
            !window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: his)),
            "his spelling is still excluded after the recording aged out"
        )
        #expect(!window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: hers)))
    }

    /// The same leak by the other road: a guest spelled out and then not.
    @Test("A guest spelled out then dropped also forgets cleanly")
    func supersetThenSubsetForgetsCleanly() {
        var window = DJRepeatWindow(historyCapacity: 2)
        window.recordPlayed(track("full", artist: "Kidswaste & Khai", title: "Wild"))
        window.recordPlayed(track("bare", artist: "Kidswaste", title: "Wild"))
        for n in 0..<2 { window.recordPlayed(track("f\(n)", artist: "Someone \(n)", title: "Song \(n)")) }
        #expect(!window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: track("x", artist: "Kidswaste & Khai", title: "Wild"))))
        #expect(!window.excludesSong(anyOf: DJRepeatWindow.songKeys(for: track("y", artist: "Kidswaste", title: "Wild"))))
    }

    @Test("A credit carried in the title does not make a second song of it")
    func creditInTheTitleIsIgnored() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Kidswaste", title: "Wild"))
        let spelledOut = track("t2", artist: "Kidswaste", title: "Wild (feat. Khai)")
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: spelledOut)))
    }

    /// The line the coarseness stops at: a different recording of the same
    /// song is not a repeat, and must not be swallowed by the same key.
    @Test("A live or remixed version stays a song of its own")
    func differentRecordingsAreNotMerged() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Aqua", title: "Barbie Girl"))
        for other in ["Barbie Girl (Live)", "Barbie Girl (Radio Edit)", "Barbie Girl (Acoustic)"] {
            #expect(!window.excludesSong(DJRepeatWindow.songKey(for: track("t2", artist: "Aqua", title: other))))
        }
    }

    /// Says what this actually does, including where it is blunt: a band whose own name carries a
    /// separator is cut at it.
    @Test("Only the first name in a credit counts, band names included")
    func leadArtistIsTheFirstNamed() {
        #expect(DJRepeatWindow.leadArtist(of: "Coldplay x Selena Gomez") == "coldplay")
        #expect(DJRepeatWindow.leadArtist(of: "Justin Bieber feat. Ludacris") == "justin bieber")
        #expect(DJRepeatWindow.leadArtist(of: "Coldplay") == "coldplay")
        // Cut, and knowingly: two different songs still differ by title, so
        // this costs a passed-over candidate rather than a wrong one.
        #expect(DJRepeatWindow.leadArtist(of: "Above & Beyond") == "above")
        // An unspaced separator is a letter, not a join.
        #expect(DJRepeatWindow.leadArtist(of: "Anderson .Paak") == "anderson .paak")
        #expect(DJRepeatWindow.leadArtist(of: "Sixx:A.M.") == "sixx:a.m.")
    }

    @Test("A genuinely different song by the same artist is not excluded")
    func differentSongSameArtistIsFine() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Aqua", title: "Barbie Girl"))
        let otherSong = track("t2", artist: "Aqua", title: "Doctor Jones")
        #expect(!window.excludesSong(DJRepeatWindow.songKey(for: otherSong)))
    }

    @Test("A track with no artist credit has no song identity to exclude by")
    func noArtistMeansNoSongKey() {
        let untitled = Track(id: id("t1"), title: "Mystery Track", artistName: nil)
        #expect(DJRepeatWindow.songKey(for: untitled) == nil)
        var window = DJRepeatWindow()
        window.recordPlayed(untitled)
        // Nothing to exclude anyone else by, but this still must not crash
        // or misbehave for the id half.
        #expect(window.excludes(untitled.id))
    }

    @Test("excludedSongKeys is the union of both halves")
    func excludedSongKeysUnion() {
        var window = DJRepeatWindow()
        window.recordPlayed(track("t1", artist: "Aqua", title: "Barbie Girl"))
        window.setQueued([track("t2", artist: "Alex Party", title: "Wrap Me Up")])
        let keys = window.excludedSongKeys
        #expect(keys.contains(DJRepeatWindow.songKey(for: track("x", artist: "Aqua", title: "Barbie Girl"))!))
        #expect(keys.contains(DJRepeatWindow.songKey(for: track("x", artist: "Alex Party", title: "Wrap Me Up"))!))
        #expect(keys.count == 2)
    }

    @Test("The oldest recording ages out of song history the same way a catalog id does")
    func songHistoryAgesOutOldest() {
        var window = DJRepeatWindow(historyCapacity: 2)
        window.recordPlayed(track("t1", artist: "A", title: "One"))
        window.recordPlayed(track("t2", artist: "B", title: "Two"))
        window.recordPlayed(track("t3", artist: "C", title: "Three"))
        #expect(!window.excludesSong(DJRepeatWindow.songKey(for: track("x", artist: "A", title: "One"))))
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: track("x", artist: "B", title: "Two"))))
        #expect(window.excludesSong(DJRepeatWindow.songKey(for: track("x", artist: "C", title: "Three"))))
    }
}
