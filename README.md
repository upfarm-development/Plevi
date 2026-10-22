# Plevi

Plevi is a music player for the library you already own, played from the server you already run. It works with Plex, and with Navidrome and other OpenSubsonic servers, on iPhone, iPad, Apple Watch and in the car with CarPlay, and it needs iOS 26.1. It's an independent project and isn't affiliated with Plex or Navidrome.

There are no accounts, ads, analytics or tracking in it. Your sign-in details are kept in the iOS Keychain, and the app only talks to the servers you add (the Privacy section has the detail).

This repository is the app's source code, published so you can see how it works. It doesn't build as an app from a clone, and the section further down explains why.

## What it can do

### Shuffle that does what you want

Shuffle doesn't have to mean random. With Smart Shuffle you decide what it favours. Rank three things in the order that matters to you: songs you've rated highly, songs you haven't heard in a while, and songs you've played least. Want your favourites on heavy rotation? Put ratings first. Want to keep things fresh and hear what you've been neglecting? Put "not played in a while" first. You can switch any of them off, and you choose how far apart two songs by the same artist, or from the same record, have to be. Nothing is ever ruled out, so every song still gets its turn. Classic shuffle is a long press away.

### Music that never runs out

- **Smart Continue.** When your queue ends, Plevi keeps going with songs that fit what you've been listening to. It looks at the whole queue, not just the last song, so the mix stays varied.
- **DJs.** Turn on a DJ and it picks what plays next, so you don't have to build a queue at all. Choose the mood. *Moody* and *Drift* stay atmospheric, *Era* stays in the decade of the song you started with, *Purist* sticks to the genre you started in, *Deep Cuts* plays songs you rarely hear, *Gold* plays only your favourites, and *Fresh* brings in what you've added lately. Or go on a *Journey*: pick a destination, like a genre, a decade or a particular song, and the DJ eases the music there one step at a time.

### Radio from your own collection

Start a station straight from Home, with no internet needed. Play your whole library, only the songs you've rated well, the deep cuts you hardly ever play, or any genres and decades you pick. If you'd rather make your own, the Mixer takes a few artists and albums and turns them into a station, with four dials to tune it: shuffle, rarely played, top rated and popular. Stations never play anything you've rated below two and a half stars (unrated songs always get a go) and never put the same artist on twice in a row.

### Decade radio that gets the decade right

A reissue shouldn't change when the music was made. Plevi places each song by when it was actually made, not by when the copy in your library was released. It uses the song's own original date when your server has one, then the record's original release date. Compilations and anthologies, which carry the year they were pressed, are placed using the years of that artist's other records in your library. So a 2020 reissue of sixties hits plays in the sixties, and a best-of is placed by the artist's other records instead of the year it was pressed. If Plevi can't tell when a song is from, it leaves it out rather than guessing.

### Find music you forgot you owned

Home keeps giving you reasons to dig back into your own library:

- **Made for You.** Mixes built from what you actually play, with a new one every day.
- **Rediscover.** Albums you haven't played in months, or ever.
- **Spotlight.** One artist gets a whole week, picked because their best albums are rated highly, and then they rest for a year so it stays special.
- **Released on This Day.** Records that came out on today's date.
- **Editors' Choice.** One well-reviewed record a day, picked from the critic scores in your library rather than from your listening, and varied so it doesn't keep landing on the same genre or decade.

### Take over another device

Your phone becomes the remote for the iPad on the kitchen counter, or the other way round. Pick another device running Plevi from the player or from Home, and whatever you play starts there: albums, artists, playlists and radio stations. You see its queue and progress, and you can skip, seek, change what's next and set the volume, including with your phone's volume buttons. The music carries on if you disconnect. Switch on Allow Remote Control in Settings on the device you want to control.

Devices find each other on your network with nothing to type in. The first time two devices connect, you confirm the same short code on both screens, and everything goes straight between the two devices over an encrypted connection.

### And the rest

- **More than one library.** Plex and Navidrome libraries can sit side by side. You switch between them quickly and can search across them.
- **Fast browsing.** The whole library is copied into a local database, so scrolling and searching are instant and don't go to the server. A background sync keeps it up to date.
- **Its own audio engine.** Playback is gapless, with fades between songs, a ten-band equaliser and loudness levelling. Ogg Vorbis is decoded on the device, since iOS can't play it by itself.
- **The usual things, done properly.** Ratings, favourites, playlists, lyrics, a sleep timer, and a seek bar drawn as the waveform of the song.
- **Offline.** Download songs, albums and playlists. Changes you make without a connection, like ratings and favourites, are sent to the server when it's reachable again.
- **Every screen.** iPhone and iPad layouts, an Apple Watch app, and CarPlay.

## Privacy

You can check all of this in the source.

- **Network:** the app talks to the servers you add. For Plex it also talks to plex.tv, to sign you in and to ask for your server's addresses. The only other address in the code is a link to the OpenSubsonic documentation. There are no analytics, advertising or crash-reporting SDKs.
- **Credentials:** passwords and tokens are kept in the Keychain, on this device only, and never synced or included in backups. Addresses and tokens are removed from the app's logs and diagnostics.
- **Remote servers:** connections to a server on the internet have to use HTTPS. Plain HTTP is only accepted for addresses on your home network, and the app warns you when you use it.
- **Self-signed certificates:** you can approve one for a single address. The app pins that exact certificate for that address and nothing else, and there's no setting that accepts any certificate.
- **Redirects:** the app never follows a redirect to a different host, because Subsonic sends sign-in details in the request and a redirect could leak them.
- **Behind a proxy or tunnel:** client certificates and custom headers, such as Cloudflare Access, are supported per server. The header values are kept in the Keychain.
- **Home and away:** each server can have a home address and a remote one. Plevi uses the home address whenever it answers, and checks that without sending any sign-in details.

## What's in this repository

| Path | Contents |
| --- | --- |
| `App` | The iPhone and iPad app, including CarPlay |
| `Watch` | The Apple Watch app |
| `Shared` | Code shared between the phone and the watch |
| `Packages/PleviKit` | The Swift package everything else is built on, described below |
| `Config`, `project.yml` | Build settings and the project definition |
| `scripts` | Scripts for numbering and archiving builds, and for making the app icon |
| `CHANGELOG.md` | What changed in each TestFlight build |

The package is split so that nothing above the server layer knows which server it's talking to:

| Module | What it does |
| --- | --- |
| `PleviDomain` | The models, and the `MusicServerProvider` protocol every server has to implement |
| `PleviSubsonicProvider`, `PleviPlexProvider` | The Navidrome/OpenSubsonic and Plex servers |
| `PleviTransport` | Connections to a server: certificates, redirects, home and remote addresses |
| `PleviKeychain` | Where secrets are stored |
| `PleviLibraryIndex` | The local database and its search |
| `PleviAudio` | Levelling, decoding and file handling for the audio engine |
| `CVorbis` | The Ogg Vorbis decoder |
| `PleviPalette` | Colours taken from album artwork |
| `PleviMockProvider`, `PleviProviderContract` | A fake server for previews, and the tests every server has to pass |

## What isn't included

Two parts of the app aren't published: Smart Fades, which plans the joins between songs, together with the audio engine that plays them, and Remote Control, the pairing and session code. Because of that this repository doesn't build as an app. It's here to be read. The package does build and pass its tests on its own:

```
cd Packages/PleviKit && swift test
```

## Licence

Copyright 2026 Upfarm Development. All rights reserved. The source is published so you can see what the app does, and no licence is granted for reuse.
