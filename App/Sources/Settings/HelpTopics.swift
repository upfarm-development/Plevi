import Foundation

// The Help section's text.
extension HelpTopic {
    static let all: [HelpTopic] = [
        // MARK: playing
        .init(
            title: "Shuffle",
            chapter: .playing,
            summary: "Two shuffle modes: one favours your best and most overlooked songs, the other is pure random.",
            body: [
                "Smart Shuffle, on by default, leans toward songs you've rated well, haven't heard in a while, or rarely play — without ever ruling anything out, so everything still gets a turn. It also keeps the same artist or album from turning up right after itself.",
                "Hold the shuffle button to use Classic Shuffle just once, or make it the default in Playback settings.",
            ]
        ),
        .init(
            title: "Smart Continue",
            chapter: .playing,
            summary: "Keeps the music playing once your queue runs out, with songs that actually fit.",
            body: [
                "A few songs before the end, Smart Continue quietly adds more — pulled from what's similar across your whole queue, not just the last song, so the mix stays varied rather than narrowing to one corner of it. It needs a server that can find similar songs.",
                "Turn it off per type of queue in Playback settings, or just for what's playing now, from Now Playing.",
            ]
        ),
        .init(
            title: "CarPlay",
            chapter: .playing,
            summary: "Your library in the car: shelves of covers, A–Z lists, and the queue from the playing screen.",
            body: [
                "Home shows shelves of covers with no titles under them — a record is quicker to recognise than to read while driving. Tapping one opens it; Play and Shuffle are buttons at the top of every record, artist and playlist. The chevron beside a shelf opens the whole shelf.",
                "Albums, artists and playlists have an A–Z index down the side of the screen. A list longer than the car will draw is cut, says so at the bottom, and loses the index, which would only describe the first part — Search in Library finds the rest. Downloads lists only what you asked for by name, the same as it does on the phone, rather than every record a downloaded playlist happens to touch.",
                "Up Next on the playing screen shows what is queued; tapping a song jumps to it. Reordering and removing stay on the phone.",
            ]
        ),
        .init(
            title: "Repeat",
            chapter: .playing,
            summary: "Off, repeat the queue, or repeat one song.",
            body: [
                "Repeat One only kicks in when a song ends on its own — skipping still moves you forward. Repeat Queue starts the whole thing over, including what you've already heard. Either mode takes over from Smart Continue rather than working alongside it, and resets to off each time you open the app.",
            ]
        ),
        .init(
            title: "Radio",
            chapter: .playing,
            summary: "Ready-made stations built straight from your library — no internet needed.",
            body: [
                "Library plays your whole collection shuffled. Highly Rated sticks to songs you've rated well. Deep Cuts favours the ones you rarely or never play. Genres and Decades let you pick one or more and play just those.",
                "Every station shares the same logic: it skips anything you've rated below 2½ stars, though unrated songs always play, and it never lets the same artist or album turn up back to back. Decades go by when a song was actually made, not when it was filed — a 2020 reissue of 60s hits still plays under the 60s.",
                "Offline, stations only draw from what's downloaded; if there's nothing to play, they say so rather than staying quiet.",
            ]
        ),
        .init(
            title: "Mixer",
            chapter: .playing,
            summary: "Build your own station from artists and albums you pick.",
            body: [
                "Choose a handful of artists or albums and the Mixer turns them into a station of up to 200 songs. Four dials shape it — Shuffle, Rarely Played, Top Rated and Popular — each nudging the odds rather than cutting anything out. It also suggests albums that share a genre with your picks, to keep the mix on theme.",
            ]
        ),
        .init(
            title: "DJ",
            chapter: .playing,
            summary: "A continuous queue that keeps picking what plays next, built around whatever vibe you choose.",
            body: [
                "The DJ favours songs that genuinely sound like what's playing, and falls back to genre and era when nothing closer is available. Pick a vibe to steer it: Moody and Drift keep things atmospheric, Era stays in one time period, Purist sticks close to the artist or genre you started with, Deep Cuts leans on underplayed songs, Gold plays your favourites, and Fresh brings in what you rarely hear.",
                "Journey is different — pick a destination, a genre, a decade or a song, and it builds a bridge that gradually gets you there before settling in.",
                "Whatever the vibe, the DJ respects your rating floor, avoids repeating an artist too soon, and won't replay anything you've heard recently. Turning it off clears what it hasn't played yet and hands your previous queue back.",
            ]
        ),
        // MARK: home
        .init(
            title: "Made for You",
            chapter: .home,
            summary: "Personal mixes built from what you actually listen to, with a new one each day.",
            body: [
                "Artist and genre mixes are ranked from your listening, weighted toward what you've played more recently. The shelf holds fourteen mixes and swaps in a new one every day, so each mix stays around for about two weeks before it's replaced.",
            ]
        ),
        .init(
            title: "Rediscover",
            chapter: .home,
            summary: "Records you haven't played in a while, or ever.",
            body: [
                "Fifteen albums you've never played, or haven't played in six months, picked once a day at random. They stay the same until tomorrow, so the shelf doesn't reshuffle every time you open Home.",
            ]
        ),
        .init(
            title: "Spotlight",
            chapter: .home,
            summary: "One artist, featured for a week, based on how well their best albums are rated.",
            body: [
                "Chosen from artists with several well-rated albums, averaging a high score across their best five. Once featured, an artist rests for a year before they can come up again, and after that artists who have been featured fewer times are the more likely.",
            ]
        ),
        .init(
            title: "Released on This Day",
            chapter: .home,
            summary: "Records released on today's date in past years, with something written about them.",
            body: [
                "Pulled from your library's release dates, and only shown once the server has notes to go with them — so the shelf fills in as answers arrive rather than all at once.",
            ]
        ),
        .init(
            title: "Editors' Choice",
            chapter: .home,
            summary: "One well-reviewed record a day, picked from the library rather than your own listening.",
            body: [
                "Chosen from albums with a genuinely good critic score — your own ratings play no part. The same record won't repeat within two months, and the pick tries not to echo the same genre or decade too soon after the last one.",
            ]
        ),
        .init(
            title: "New Releases & Just Added",
            chapter: .home,
            summary: "The newest music in your library, sorted two different ways.",
            body: [
                "New Releases sorts by when a record actually came out. Just Added sorts by when it landed in your library — the one to check for what showed up this week, whatever the release date says.",
            ]
        ),
        .init(
            title: "Recently Played",
            chapter: .home,
            summary: "What you deliberately put on — albums and playlists — not everything you've heard.",
            body: [
                "Only starting an album or a playlist counts; radio, the DJ, mixes and loose songs don't show up here. A playlist is logged as itself, not as the records its songs happen to come from.",
            ]
        ),
        .init(
            title: "Your own shelves",
            chapter: .home,
            summary: "A Home shelf built from your own rules — any album or song filter you set up.",
            body: [
                "Set rules on albums or songs and pin the result to Home as its own shelf, rebuilt fresh from your library every time it's shown. A shelf only appears once it's switched on and actually has something to show.",
            ]
        ),
        .init(
            title: "Pinned",
            chapter: .home,
            summary: "The one shelf that holds exactly what you put there.",
            body: [
                "Pin any album, artist, playlist or collection from its long-press menu, and unpin it the same way. New pins go to the front of the shelf.",
            ]
        ),
        // MARK: library
        .init(
            title: "Filter",
            chapter: .library,
            summary: "Build rules to narrow songs, albums or artists down to exactly what you want.",
            body: [
                "Rules can ask about almost anything — title, genre, rating, play count, year and more — combined as match all or match any, nested as deep as you like. Songs also have a Playlist Name rule, so you can filter to songs that are in a particular playlist.",
                "A filter can be saved as a Home shelf, a regular playlist, or — where your server supports it — a smart playlist kept on the server itself.",
            ]
        ),
        .init(
            title: "Sort",
            chapter: .library,
            summary: "Pick what a list is ordered by, and which direction.",
            body: [
                "Songs, albums and artists each offer their own relevant options — title, date added, rating, play count and so on — with a direction to match, like newest first or highest rated first.",
            ]
        ),
        .init(
            title: "A–Z index",
            chapter: .library,
            summary: "A quick-jump index down the side of an alphabetical list.",
            body: [
                "Appears automatically once a list is sorted alphabetically, so you can jump straight to a letter instead of scrolling.",
            ]
        ),
        .init(
            title: "Collections",
            chapter: .library,
            summary: "Your server's own curated sets of albums or artists.",
            body: [
                "Listed exactly as your server groups them, split into album collections and artist collections.",
            ]
        ),
        .init(
            title: "Search",
            chapter: .library,
            summary: "Fast search across artists, albums, tracks and playlists that ignores punctuation.",
            body: [
                "Matches substrings rather than only whole words, and treats apostrophes and hyphens loosely, so small differences in punctuation don't stop a match.",
            ]
        ),
        // MARK: downloads
        .init(
            title: "Download",
            chapter: .downloads,
            summary: "Keep an album, artist, playlist, filtered list or single song on your phone.",
            body: [
                "A song can be kept for more than one reason at once — say, as part of both an album and a playlist. It only comes off your phone once every reason for keeping it has been removed.",
            ]
        ),
        .init(
            title: "Downloaded vs. on your phone",
            chapter: .downloads,
            summary: "A download is deliberate; a cached song is not — and the Downloads screen only counts the first.",
            body: [
                "Songs you download stay until you remove them. Songs you've merely streamed sit in a separate cache that iOS can clear on its own when space runs low. On the Downloads screen, Albums and Artists show only what you actually asked to download by name — not every record a downloaded playlist happens to touch.",
            ]
        ),
        .init(
            title: "Download settings",
            chapter: .downloads,
            summary: "Format, mobile data, and what happens when you stop or relaunch.",
            body: [
                "Downloads have their own format setting, separate from streaming. Downloading over mobile data is off by default; Download Anyway spends your current connection just this once. Stopping keeps whatever has already finished and cancels the rest cleanly, and a downloaded playlist can be refreshed against the server to pick up renames or track changes.",
            ]
        ),
        // MARK: data
        .init(
            title: "Offline mode",
            chapter: .data,
            summary: "Switch the app to work from what's on your phone, on purpose.",
            body: [
                "Different from a dropped connection — the app tells you which is happening. Turn it off and anything you rated or played offline is sent as soon as you're back online.",
            ]
        ),
        .init(
            title: "Offline changes",
            chapter: .data,
            summary: "Ratings and plays made without a connection are saved and sent later.",
            body: [
                "They show up on your phone immediately, and wait quietly until the server is reachable again.",
            ]
        ),
        .init(
            title: "Plays and scrobbles",
            chapter: .data,
            summary: "How a play gets counted and sent to your server.",
            body: [
                "A play counts once you're halfway through a song, or when it finishes — skipping early doesn't count as a play. It's saved on your phone first, then sent to the server, so nothing is lost if you're offline when it happens.",
            ]
        ),
        .init(
            title: "Library sync",
            chapter: .data,
            summary: "Pulling your whole library down to the phone for fast, offline-friendly browsing.",
            body: [
                "Runs in the background and keeps the app's local copy in step with your server, so browsing and filtering stay fast without a request every time.",
            ]
        ),
        .init(
            title: "Space used",
            chapter: .data,
            summary: "What downloads actually cost, per server and per library.",
            body: [
                "Shown on the Downloads screen and in Downloads & Data. Removing all downloads clears the files but never touches anything on your server.",
            ]
        ),
    ]
}
