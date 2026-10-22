import Foundation
import Testing
@testable import PleviDomain

@Suite struct LyricsFileTests {
    /// The shape a real `.lrc` arrives in: metadata tags at the head, then
    /// stamped lines, with hundredths on the stamps.
    @Test func readsAnLRCFile() throws {
        let file = """
        [ar:Natasha Bedingfield]
        [ti:These Words]
        [al:Unwritten]
        [00:00.50]These words are my own
        [00:04.25]From my heart flow
        [00:09.00]I love you, I love you, I love you, I love you
        """
        let lyrics = try #require(LyricsFile.parse(file))

        #expect(lyrics.synced)
        #expect(lyrics.lines.count == 3)
        #expect(lyrics.lines[0].start == 0.5)
        #expect(lyrics.lines[0].text == "These words are my own")
        #expect(lyrics.lines[1].start == 4.25)
        #expect(lyrics.lines[2].start == 9)
        // The metadata tags are not words anyone wants to read.
        #expect(!lyrics.lines.contains { $0.text.hasPrefix("[") })
    }

    /// Minutes have to carry, and the seconds field is bounded — a bare
    /// `[75:00]` is 75 minutes in, not an hour and a quarter misparsed.
    @Test func readsMinutesAndFractions() throws {
        let lyrics = try #require(LyricsFile.parse("""
        [01:05]One
        [02:30.75]Two
        [03:07:50]Three
        """))
        #expect(lyrics.lines.map(\.start) == [65, 150.75, 187.5])
    }

    /// One line, sung more than once. Both moments are lines of their own, in
    /// order, which is what makes a chorus follow along rather than light up
    /// the first time and never again.
    @Test func aLineWithSeveralStampsBecomesSeveralLines() throws {
        let lyrics = try #require(LyricsFile.parse("""
        [00:30.00][01:30.00][02:30.00]Chorus
        [01:00.00]Verse
        """))
        #expect(lyrics.lines.count == 4)
        #expect(lyrics.lines.map(\.start) == [30, 60, 90, 150])
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus", "Chorus"])
    }

    /// Out-of-order stamps happen in hand-edited files.
    @Test func linesComeBackInTimeOrder() throws {
        let lyrics = try #require(LyricsFile.parse("""
        [00:20.00]Second
        [00:10.00]First
        """))
        #expect(lyrics.lines.map(\.text) == ["First", "Second"])
    }

    @Test func readsTheOffsetTagAsSeconds() throws {
        let lyrics = try #require(LyricsFile.parse("""
        [offset:-500]
        [00:10.00]Line
        """))
        #expect(lyrics.offset == -0.5)
    }

    /// A plain sheet of words. Blank lines between verses survive, because
    /// without the timing they are all that separates them.
    @Test func readsPlainText() throws {
        let lyrics = try #require(LyricsFile.parse("""
        These words are my own

        From my heart flow
        """))
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["These words are my own", "", "From my heart flow"])
        #expect(lyrics.lines.allSatisfy { $0.start == nil })
    }

    /// A file the server calls LRC that has no stamps in it is plain text,
    /// whatever its extension says.
    @Test func aFileWithNoStampsIsUnsynced() throws {
        let lyrics = try #require(LyricsFile.parse("""
        [ar:Someone]
        Just the words
        And more of them
        """))
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["Just the words", "And more of them"])
    }

    /// Nothing worth putting on screen comes back as nothing, so the button
    /// can be switched off rather than opening an empty page.
    @Test func nothingWorthShowingIsNil() {
        #expect(LyricsFile.parse("") == nil)
        #expect(LyricsFile.parse("   \n\n  \n") == nil)
        #expect(LyricsFile.parse("[ar:Someone]\n[ti:Something]\n[al:Somewhere]") == nil)
    }

    /// Words that happen to open with a bracket are words.
    @Test func bracketedWordsAreNotTags() throws {
        let lyrics = try #require(LyricsFile.parse("[Chorus]\nSing along"))
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["[Chorus]", "Sing along"])
    }

    /// Windows line endings, which is most lyric files found in the wild.
    @Test func handlesCarriageReturns() throws {
        let lyrics = try #require(LyricsFile.parse("[00:01.00]One\r\n[00:02.00]Two\r\n"))
        #expect(lyrics.lines.map(\.text) == ["One", "Two"])
    }
}
