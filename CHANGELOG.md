# Changelog

User-facing changes, newest first.

## 0.1.0 (490)

IMPROVED

- The Remote Control button on Home is only tinted while a device is controlling or being controlled.

---

## 0.1.0 (489)

IMPROVED

- Controlling another device and being controlled now look the same. On iPhone
  and iPad, controlling shows a small oval, "Playing on iPad" in blue; being
  controlled shows a slim oval, "Controlled by iPhone" with Disconnect beside
  it, in place of the grey bar across the top.
- On iPhone, the oval sits over the corner of the album art, so a phone that is
  controlling another device now says so. Tapping it opens the device list.
- The volume slider on iPhone sits within the page margins and is slimmer. The
  album art gives up a little height while it is showing, so the controls
  below stay where they were instead of being pushed off the screen.
- The device button on the Home screen is the Remote Control button, with no
  AirPlay entry in its list.

---

## 0.1.0 (488)

FIXED

- The AirPlay button on the player lists your AirPlay and Bluetooth speakers
  again. Once Remote Control had been used, it had been replaced by a list of
  other devices running Plevi, with AirPlay hidden behind it.

IMPROVED

- Remote Control has its own button on the player, beside AirPlay. It appears
  once you have used Remote Control, and shows the device you are controlling
  when you are.

---

## 0.1.0 (487)

FIXED

- A song whose download broke off in its first moments, as the output moved to
  AirPlay, no longer plays only the few seconds that had arrived and then
  stops. It is fetched again instead.
- When a song does have to be played out from what arrived, the next song is now
  read ahead, so it is ready when its turn comes.

WORTH KNOWING

- A download that breaks off once you are more than a few seconds in still
  plays out what arrived, with the error shown, as before.
- If it happens again, the playback log now names the cause.

---

## 0.1.0 (486)

IMPROVED

- The History and Up Next tabs no longer show as a sliver at the bottom of the
  player. They now start just below the edge of the screen, so the player page
  looks complete until you scroll to the queue.

---

## 0.1.0 (485)

IMPROVED

- Switching Smart continue off while you are scrolled down the queue no longer
  throws the page back to the top. It stays where it was, with blank space under
  the shortened queue until you scroll up or switch it back on.

---

## 0.1.0 (484)

IMPROVED

- The queue on iPhone keeps your place when you switch tabs. Scrolled down on
  Up Next and then switching to a short History, the page used to jump back to
  the top; it now stays where it was, with blank space under the short list
  until you scroll up or go back to Up Next.
- Smart continue no longer adds the same songs every time. Its picks vary, so
  turning it off and on again gives a fresh set. Switching it back on fills the
  queue straight away if it is running low.

WORTH KNOWING

- Songs that several of the queue's songs agree on are still the likeliest to
  be added, so the mix stays in character; what varies is which of the close
  matches make it in.

---

## 0.1.0 (483)

IMPROVED

- A trial: the queue on iPhone now borrows the iPad's layout. History and Up
  Next are a segmented control across the top, and below it Smart continue is a
  switch on the left with Clear on the right.
- The song that is playing no longer appears at the top of History. It joins the
  list once playback has moved on from it.

WORTH KNOWING

- "Moved on" means it ended or was skipped; either way it is in History
  afterwards, as before.
- Clear on History leaves the playing song alone, and it still appears when it
  is over.

---

## 0.1.0 (482)

IMPROVED

- New setting, "Refresh album details at launch", under Downloads & Data (on by
  default). Music you have already downloaded now picks up what changed on the
  server since: an album review written after you downloaded it, a cover that
  was replaced, a title that was corrected. Reviews are fetched for downloaded
  albums that have none, which includes everything downloaded before build 481.

WORTH KNOWING

- A replaced cover is noticed when the server gives it a new identity, which
  Plex does. A server that swaps the picture without changing its identity will
  not be noticed.
- Up to 100 albums are asked about per launch, so a large library may fill in
  over a few launches. An album with no review is asked about again after a
  week, not every launch.

---

## 0.1.0 (481)

IMPROVED

- 96 kbps is back in the list of bit rates to convert to.
- Streaming can now treat Wi-Fi away from home like mobile data. Turn on "Treat
  other Wi-Fi as cellular" under Downloads & Data, and the original files stay
  for your home network while a hotel or office network gets your Cellular
  setting. It needs a server with both a home and a remote address.
- Album reviews are kept on the phone, so an album's About section reads offline.
  Downloading songs fetches the reviews of their albums as well.
- Turning Smart Continue off takes back the songs it added that you have not
  reached yet. The record you started and anything you queued yourself stay.
- The watch is sent your library once a day in the background if it has not had
  one, instead of only after a sync that changed the number of songs.

FIXED

- Adding a song while the next song's fade was being set up could show your song
  as next while the song that was queued before it played.

WORTH KNOWING

- If the fade into the next song has already begun when you add a song, that
  song is already audible and plays out; yours follows it.
- Smart Continue forgets which songs it added when the app is closed and
  reopened, so turning it off after that clears nothing.
- iOS decides when the daily watch send runs.

---

## 0.1.0 (480)

IMPROVED

- Downloads shows what was on the phone as soon as the app opens, instead of
  saying "Nothing downloaded" for a few seconds after a cold launch.
- The question that comes up when you remove a song from a playlist now rises
  from that song. The same goes for removing every download, removing a server
  and restoring settings, which now come up from the control you pressed.

FIXED

- A downloading song's title no longer shrinks and grows as the percentage
  counts up.
- A playlist that is fully downloaded no longer offers "Download Missing" on
  its long-press menu.
- The three-dot menu on Downloads no longer flashes while downloads are
  running.

---

## 0.1.0 (479)

FIXED

- Scrolling a page with a coloured header is smoother: the page no longer
  redraws itself on every frame of an ordinary scroll, which showed as late
  frames and the page jumping two or three times its step.

---

## 0.1.0 (478)

FIXED

- Downloads no longer stay paused for good after you change library while a
  song that is not downloaded is arriving. The pause is lifted when the library
  changes, and kept only if a song is being fetched at that moment.
- The artwork cache now stays within its limit across all your libraries
  together, as the play cache does, instead of each library's folder being held
  to it separately.
- The covers kept with downloaded music are cleaned up when the downloads are
  removed, and a download made while covers were being kept is now picked up
  instead of being missed.

---

## 0.1.0 (477)

FIXED

- The play cache now stays within the limit you set across all your libraries
  together, rather than each library's folder being held to it separately.
- The page-header size of a downloaded song's or playlist's artwork is kept
  with the download too, so those pages keep their full-size cover offline.

---

## 0.1.0 (476)

FIXED

- Pages for downloaded music no longer turn white-on-white offline when their
  artwork cannot be loaded. The backdrop now falls back to the same dark scheme
  as the text.

IMPROVED

- The covers and colours of downloaded songs and playlists are now kept with
  the download, so they are still there after a cold launch offline, once the
  artwork cache has filled, and after "Clear artwork cache".

---

## 0.1.0 (475)

FIXED

- A song streamed straight after an Ogg Vorbis one no longer shows "Vorbis" in
  the format badge. The badge named the previous song's file until the new one
  had finished arriving.

---

## 0.1.0 (474)

IMPROVED

- Spotlight, the artist of the week, now rests a featured artist for a year
  instead of six months, and after that favours artists who have been featured
  fewer times, so you are far less likely to be shown someone you saw recently.
  It is still a different pick every week rather than a fixed rotation. Nobody
  who has had a turn is shown again within a year, unless the library has too
  few eligible artists for that to be possible.

---

## 0.1.0 (473)

IMPROVED

- The waveform is dialled back another step: fewer bars reach the top of the
  strip, so the loud and quiet parts of a song read as the difference they are.
  Quiet songs still show their shape.

FIXED

- Playing a song that is not downloaded while downloads are running no longer
  fails with "the network connection was lost" after the first few seconds.
  Downloads now wait while the song you chose arrives, then carry on from where
  they stopped.

---

## 0.1.0 (472)

IMPROVED

- Long albums are built as one list that fills in as you scroll, instead of
  nested lists, so the page no longer has to re-measure itself while you scroll.
  Short albums and the two-column iPad layout behave as before.
- Artist pages fetch every album cover in the background as soon as the page has
  appeared, so scrolling down finds them already there instead of showing grey
  placeholders. This covers grids, carousels and lists, the Similar Artists
  section and the song carousels, loads in the order you have set up the page,
  and stops when you leave it.

FIXED

- On artist pages the Albums section no longer jumps down, sometimes over the
  Popular songs, while the page is still loading. The song shelves and the
  Similar Artists grid are laid out at once, and About holds the room of a long
  biography while it loads, then shrinks for a short one or goes away when the
  artist has none.

---

## 0.1.0 (470)

IMPROVED

- The waveform of a quiet song is now lifted gently instead of all the way. In
  the last build most songs reached the top of the strip, and a quiet song with
  little movement jumped from half height to the top. Quiet songs still show
  their shape, loud songs look as they always did, and the middle sits in
  between.

---

## 0.1.0 (469)

NEW

- Downloads: long-pressing a downloaded playlist now offers Open, Play, Shuffle
  and Remove Download, and long-pressing a downloaded artist offers the same menu
  as everywhere else in the app.
- A downloaded playlist's page has Remove Download in its "..." menu.

IMPROVED

- The waveform now shows the dynamics of quiet songs. Soundtracks and other
  quiet recordings used to draw as a row of dots; each song is now lifted by its
  own loudness, and loud songs look as they did.

CHANGED

- Settings > Storage & Data is now called Downloads & Data.

---

## 0.1.0 (468)

IMPROVED

- Playlists open faster. A playlist you have opened or scrolled past now shows
  its first songs straight away, and the server's answer corrects them a moment
  later. Smart playlists, such as the heart-rated one, no longer open to an empty
  list while the server works out its songs.

---

## 0.1.0 (467)

IMPROVED

- Large albums, such as soundtracks with a hundred songs or more, open faster:
  the list now only builds the rows you can see.

---

## 0.1.0 (466)

FIXED

- The Released on This Day carousel on Home no longer spins through several
  cards when you reopen the app. It stops while the app is away and starts
  again, from the beginning of a pause, when you come back.

---

## 0.1.0 (465)

NEW

- Ogg Vorbis files now play. They are decoded on the phone, so there is no
  conversion to Opus any more, and the badge says VORBIS.
- A downloaded Plex song shows its own embedded cover when it differs from the
  album's, on Now Playing and in the queue.

FIXED

- Track numbers of three digits are no longer cut short on album pages.
- Offline, a FLAC's badge reads 48/16 again instead of 48.
- iPad: the offline message sits above the tab bar instead of covering it.
- A downloaded playlist is no longer empty when the app is opened with no
  connection, and shows a cover from its first song if its own is gone.
- Rating or favouriting a song responds at once.

WORTH KNOWING

- A Vorbis song starts a moment after you tap it, once it has downloaded and its
  first seconds are decoded.

---

## 0.1.0 (464)

FIXED

- Repeat: turning it on near the end of an album no longer lets one extra song
  from Smart Continue play first, and a Smart Continue fetch already under way
  no longer adds songs after you turned Repeat on.
- Shuffle: turning it off no longer drops the songs Smart Continue added into the
  middle of the album, and Add to Queue goes before them rather than behind.
- Previous after Shuffle goes back to the song you heard before, instead of
  restarting the same one.
- A Smart Continue that fails offline is tried again later, instead of giving up
  for the rest of the queue.
- The sleep timer no longer lets a song that was still loading start playing
  afterwards.
- Removing a download of an album or artist from another library keeps songs you
  also kept for a playlist there.
- Another library's album and artist pages keep showing what is downloaded.
- Switching library while music plays keeps the next song coming, and reading the
  other libraries in the background no longer runs on mobile data or in Low Power
  Mode.
- A song that appears to stall with the audio still running no longer restarts
  from the top.

---

## 0.1.0 (463)

FIXED

- A song no longer restarts a few seconds in after a gapless join when you play
  through a Bluetooth speaker.
- The system volume overlay shows again when you press the volume buttons. It
  is hidden only while Remote Control is connected.
- iPhone: Now Playing shows the waveform as it arrives again, instead of a
  plain line first.

WORTH KNOWING

- While your iPhone or iPad is controlling another device, or being controlled,
  the system volume overlay stays hidden.

---

## 0.1.0 (462)

NEW

- Libraries you tick under Quick Switch are read in the background, so search
  across libraries finds them without you having to switch to them first. A
  note tells you when a library is being read for the first time and when it is
  ready.

FIXED

- Repeat now repeats the album when Smart Continue is on, instead of carrying
  on into similar songs first.
- Shuffle on Now Playing shuffles the whole album or playlist, with the playing
  song carrying on first, not only the songs still to come. Turning it off puts
  everything back in order.

WORTH KNOWING

- A large library takes a while to read the first time.

---

## 0.1.0 (461)

NEW

- Settings › Storage & Data: Merge downloads from all libraries. Turn it on and
  Downloads also lists what you kept in your other Quick Switch libraries,
  marked with the library's name, and plays and opens it. CarPlay's Downloads
  follows the same list.

FIXED

- Albums and artists found in another library's search results now offer
  Download, and Remove Download once kept.
- An album you download from another library's search results now shows as an
  album in Downloads, not only as its songs.
- Long press on a pinned album or artist, and on an album under Recently
  Played, now offers the same menu as everywhere else, including Download.

WORTH KNOWING

- Downloaded playlists from your other libraries aren't in the merged list yet,
  and Remove All Downloads still clears only the open library.

---

## 0.1.0 (460)

CHANGED

- Switching library with the quick picker no longer stops what is playing, when
  the other library is on the same Plex server.
- Artist menu: Play Unrated now sits under the Play Next and Add to Queue row.

FIXED

- iPad: after switching library, opening Now Playing no longer leaves the
  artwork standing still while the rest of the card slides up.

WORTH KNOWING

- After a library switch, a queue that carries on playing may not extend itself
  with similar songs, since the new library does not know them.

---

## 0.1.0 (459)

NEW

- iPad album grids: Settings › Library has Grid density, Low or High. Low is
  three across in portrait and four in landscape; High is four and five.
- Remote control: a rating or favourite you set on the controlling device now
  shows on the device being controlled straight away, and on the controller too.
- Remote control: volume now moves the other device's own volume, up as well as
  down, and follows its volume buttons.

FIXED

- Disconnecting from a device no longer leaves Now Playing open on a black page.
- Remote control: after unlocking the controlling device, a dead connection is
  redialled, and Now Playing keeps what it was showing, saying "Reconnecting".
- iPad: opening Now Playing after coming back to the app no longer leaves the
  artwork standing still while the rest of the card slides up.
- iPad: the waveform seek bar now travels up with Now Playing instead of
  standing still while it rises. A song whose shape is already known shows it
  from the start; a new one rises as a flat line and the waveform fills in once
  the card has landed.

WORTH KNOWING

- Remote volume needs the controlled device open on screen.
- A song's rating shows on the other device only when both use the same library.

---

## 0.1.0 (458)

FIXED

- A song that was still downloading when it started no longer ends thirteen
  seconds early, with the next song cutting in over the rest of it.
- Fades between songs now follow the song's own loudness. Quiet records used to
  get no transition at all, and loud ones overlapped while still loud.

WORTH KNOWING

- Transitions will sound different from before, most on very quiet and very
  loud masters.
- The playback log now says why each song joined the next the way it did.

---

## 0.1.0 (457)

Build 456 was never uploaded; its changes are below.

FIXED

- iPad: after a cold launch, the waveform seek bar no longer stays put while
  Now Playing slides up; it travels with the card like everything else.
- Playback settings: the Smart Continue switches had collapsed on top of one
  another. Each has its own row again.

CHANGED

- The waveform seek bar is finer on iPad: more, thinner bars across the wider
  space. On iPhone it looks the same.

---

## 0.1.0 (455)

FIXED

- Rediscover: tapping See More now shows the same ten records as the shelf,
  followed by ten more, instead of a new random set each time. The shelf itself
  shows ten and holds still for the day.

WORTH KNOWING

- Rediscover changes once when you first open this build, as today's pick is
  redrawn at its new size.

---

## 0.1.0 (454)

FIXED

- Tapping an artist in the full Similar Artists list now opens that artist's
  page on top of the list, and back takes you to the list. It used to put the
  list back on top of the artist's page, so the page seemed to be skipped.

---

## 0.1.0 (453)

Recently Played and pinned albums from another library open again. Build 452
was never uploaded; its change is below.

FIXED

- An album you played from another library, after finding it with search across
  libraries, no longer shows as missing on Recently Played. Albums already there
  open again, and pinned albums and artists from another library do too.

REMOVED

- Born on This Day, the Home shelf of artists with a birthday today, and its
  switch in Settings › Library. Nothing is sent to musicbrainz.org any more;
  the app now talks only to your own server.

---

## 0.1.0 (452)

REMOVED

- Born on This Day, the Home shelf of artists with a birthday today, and its
  switch in Settings › Library. Nothing is sent to musicbrainz.org any more;
  the app now talks only to your own server.

---

## 0.1.0 (451)

FIXED

- Settings → App Icon now marks the icon you are actually using. It could come
  back showing the default as selected even though another was in use.

---

## 0.1.0 (450)

Two animation fixes on the iPad player.

FIXED

- Opening the queue in landscape: the song title and names now slide along with
  the shrinking artwork instead of jumping across it. In portrait the rating and
  format badge slide too.
- The seek bar now rises with the player when you open it right after starting
  the app, or after it has been in the background for a while.

WORTH KNOWING

- Please try the second one specifically: open the app fresh, then open the
  player. Say if the progress bar still stays put while the rest slides up.

---

## 0.1.0 (449)

Two fixes for songs and records from your other libraries.

FIXED

- A record you played after finding it through a search across libraries could
  show up on Home under Recently Played and then say it was not in your library
  when tapped. It now opens, as long as that library is still ticked under
  Quick Switch. Pinned records and artists work the same way.
- Continuing the queue no longer adds the song that is already playing again,
  or another copy of a song that is already in the queue — the same song on a
  different album or compilation counts as the same song.

WORTH KNOWING

- Offline, a record from another library does not open from Home; the card
  tells you which library it is in.

---

## 0.1.0 (448)

A large round of fixes for things that could go wrong with downloads, playback,
Remote Control and the watch.

FIXED

- Downloads are safer. A refresh keeps your old copy until the new one has
  arrived, and nothing is deleted just because something could not be read.
  Files that turn out not to be songs are treated as failures.
- Playback: lossless files start early again, poor connections are handled
  better, and leaving Wi-Fi stops the app trying to pre-load the next songs.
- Reconnecting after losing the network is more reliable, and the app says why
  when it cannot connect.
- Switching between servers or libraries no longer leaves the old one's pages,
  waveforms or settings behind.
- A rating or heart the server turns down is put back, with a message saying
  why.
- Settings, your server list and your backup are no longer overwritten when
  something could not be read.
- Lists, playlists and search are more reliable: a failed load no longer shows
  up as an empty list, and playlists that are still loading can be played.
- CarPlay stays in step with the app and tells you when something fails.
- Remote Control is tougher: commands that do not work say so, a stalled
  connection gives up instead of hanging, and rating or playlist actions no
  longer land on the wrong device.
- Apple Watch: it picks the right server address when the network changes,
  kept songs play sooner, and plays made offline are sent when it can.

WORTH KNOWING

- This touches a lot. Worth trying: switch library while a song plays, turn
  Wi-Fi off and on with a rating waiting to be sent, and run downloads on
  mobile data. Please say if anything there behaves differently.

---

## 0.1.0 (447)

The iPad player, tidied up.

NEW

- The queue on iPad now opens and closes like a drawer, sliding in from the
  edge. It also stays as you left it when you turn the iPad: open in portrait,
  still open in landscape.

CHANGED

- On iPad the mini player is now as wide as the tab bar and centred, instead
  of stretched across the whole screen.
- The full player rises as one piece. The waveform, the format badge and the
  album year used to sit in place while everything else slid up past them.
- The iPad player's layout follows the new design: the title and names sit on
  the seek bar, and the queue has a History / Up Next switch at the top.

FIXED

- The artist name stayed put while the player slid up, on songs with more than
  one artist.

WORTH KNOWING

- Turning the iPad with the player open still shows the app behind it for a
  moment at the edges. Please say if it bothers you.

---

## 0.1.0 (446)

Settings say less.

CHANGED

- Most of the small explanatory text under settings is gone. What is left is
  what you would otherwise be surprised by: where your data goes, what a
  setting needs before it does anything, and live status.

WORTH KNOWING

- Nothing works differently. If a setting now feels too bare, say which one.

---

## 0.1.0 (445)

Downloads now open and play whatever your connection is doing.

FIXED

- A downloaded playlist could come up blank on a poor or mobile connection,
  even though every song was on the phone, until you force-quit the app. It now
  opens straight from the phone whatever the connection is doing.
- After leaving your home Wi-Fi with the app open, everything that asked your
  server for something could sit there for half a minute with nothing showing.
  The app now works out which address to use again when your network changes and
  when you come back to it, and says "There's no network connection" when there
  isn't one.
- Artist and album pages opened from Downloads no longer wait on the server
  before they show what's on the phone.
- A downloaded song that was saved as a converted copy is now played when the
  server can't be reached, instead of trying to stream it.

WORTH KNOWING

- Worth trying: go into Downloads on mobile data, and again in airplane mode.
  Playlists, albums, artists and songs should all open and play at once. Please
  say if anything there still hangs.
- The Playlists tab (streaming from the server) recovers by itself after you
  leave Wi-Fi, but still needs the server.

---

## 0.1.0 (444)

More Remote Control work, still developer-only.

FIXED

- Remote Control (one of your Plevis controlling another on the same Wi-Fi):
  the device picker now names the device ("Kitchen iPad", "iPad") instead of
  "New device", and connecting and disconnecting are much less likely to leave
  you stuck on "Connecting…". Cancelling works, turning Allow Remote Control
  off ends any live session, choosing a different device switches to it, and the
  code comparison now shows on the controlling device too.
- The other device's volume slider and the hardware volume buttons stay in step
  with what's actually playing.

WORTH KNOWING

- Needs two devices, and is still a developer feature — nothing here changes
  anything if you don't use it.

---

## 0.1.0 (443)

Search can now look through your other Quick Switch libraries.

NEW

- Settings › Search has a new switch, "Search all quick libraries", off by
  default. Turn it on and Search also looks through the other libraries you've
  ticked under Quick Switch, so a song from your kids' library turns up while
  the main one is open, and you can play it from there. Results from another
  library carry a small label with that library's name; results from the open
  library look the same as before.

WORTH KNOWING

- Plex only, and it needs two or more libraries ticked under Quick Switch in
  your Plex server's settings. A library is only searched once it has been
  opened and synced at least once.
- Results from the open library still come first, so a search with plenty of
  matches in the main library may show the other library's ones under "More".
- Worth trying: search for something from the other library, play it, open its
  album, and open its artist. Please say if any of those misbehave.

---

## 0.1.0 (442)

Adding a Navidrome server no longer drops you onto an empty Home, and a first
failed connection no longer shows an error straight away.

FIXED

- After signing in to a Navidrome or Subsonic server, the "Setting up your
  library" screen could vanish partway and leave you on an empty Home while the
  library loaded behind it. It now stays until the first sync has finished,
  including after a Try Again.
- A first connection that failed for a moment used to show "Couldn't reach your
  server" at once. It now keeps trying quietly for a few seconds under the same
  "Reaching your server" spinner, the way Plex already did, and only says so if
  it still can't get through.

WORTH KNOWING

- The Remote Control developer screen in Settings has had a lot of work since
  the last build (seek bar, background drops, hardware volume buttons, and the
  device picker now names the device you're connected to). It is still a
  developer screen, not something to rely on.

---

## 0.1.0 (440)

Nothing to test in this build — more Remote Control fixes, still developer-only.

WORTH KNOWING

- Two more fixes to the in-progress, developer-only Remote Control
  feature: a paired device no longer needs re-approving every 30 days,
  and a possible cause of the connect screen hanging forever was found
  and bounded. Still nothing here for anyone but the developer to try.

---

## 0.1.0 (439)

Nothing to test in this build — a Remote Control fix, still developer-only.

WORTH KNOWING

- A connection bug in the in-progress Remote Control feature was fixed,
  but it's still the same developer-only screen from the last two
  builds, not something to try.

---

## 0.1.0 (438)

Nothing to test in this build either.

WORTH KNOWING

- Settings now shows a "Remote Control (developer)" row in every build,
  not just a tethered debug one — it's still a developer-only screen for
  a feature that isn't ready for anyone else yet, not something to try.

---

## 0.1.0 (437)

Nothing to test in this build.

WORTH KNOWING

- This build merges in the first pass of a Remote Control feature
  (pairing and control between your own Plevis on the same Wi-Fi), but
  it's switched off for anyone but the developer — there's nothing new
  to see or try here.

---

## 0.1.0 (436)

A fix for songs that occasionally went by silently and got skipped.

FIXED

- A song could occasionally play in total silence and then get skipped,
  with nothing to explain it. If playback goes quiet on a song and it
  jumps to the next one within a couple of seconds, that's this fix
  catching it — much better than losing the rest of the song to it.

WORTH KNOWING

- This can only really be judged by whether the original problem stops
  happening, which takes time to know. If a song still goes missing
  after this build, please report it — this build also added logging
  that should explain a lot more about what happened.

---

## 0.1.0 (435)

Loudness levelling actually levels now, across gapless joins and crossfades.

FIXED

- Levelling could quietly stop applying and let a run of tracks play at
  whatever gain the first one happened to have — most noticeable across
  gapless joins and crossfades, which were silently exempt before this.
- A crossfade briefly played the incoming song at the outgoing song's
  volume for the first half of the overlap, rather than its own.

NEW

- A Preamp stepper in Settings › Playback, under levelling — turn it up
  if levelled tracks feel quiet, or down if something clips.

WORTH KNOWING

- If you run levelling, this is worth a real listen across a few
  transitions — gapless, crossfaded, and an ordinary track change.

---

## 0.1.0 (434)

One fix: a low-rated song could sneak into a "Made for You" mix.

FIXED

- A mix seeded on an artist with little genre or date information in your
  library could let a song you'd rated two stars or below back in,
  instead of holding it to the same floor every other mix already did.

WORTH KNOWING

- If you'd noticed a low-rated song turning up in a specific mix before,
  it's worth checking that one again.

---

## 0.1.0 (433)

A round of fixes from reviewing everything shipped in 426 through 432. No
new features.

FIXED

- The player's artwork could blank for a frame during a rotation or a
  Split View resize, on iPhone and the framed iPad layout.
- A Born on This Day card's picture could fail to appear if it was drawn
  before the app had finished connecting to your server, with no way to
  recover once it did.
- A rare race in the background MusicBrainz lookups that could let two
  requests through faster than intended.
- CarPlay search could keep working on a query after you had already
  typed the next letter, wasting work on a car's more limited hardware.

WORTH KNOWING

- Nothing here changes what any screen looks like or how a feature
  behaves — this build is corrections found reviewing the last six.

---

## 0.1.0 (432)

Search in CarPlay, and no more artwork flash between songs on the same album.

NEW

- CarPlay: a search button in the Library tab opens CarPlay's own keyboard
  search — artists, albums, playlists and songs. Tapping a song plays it
  and the rest of that search's results, the same as tapping one in Songs.

FIXED

- CarPlay no longer flashes the album art between two songs on the same
  record. It was rebuilding the artwork from scratch on every track
  change, even when the picture had not actually changed.

WORTH KNOWING

- CarPlay search needs a real head unit or a car display to try — it uses
  CarPlay's own keyboard, which the Simulator cannot show.

---

## 0.1.0 (431)

A new Home shelf for artist birthdays, and radio stations that stay on genre.

NEW

- Born on This Day, a Home shelf for artists in your library born (or
  formed, for a group) on today's date. Off by default — turn it on in
  Settings › Library. It needs a MusicBrainz id, which a sync matches
  where it can, and a background lookup afterwards, so give it a sync or
  two before expecting anything on Home.

FIXED

- Song Radio and Artist Radio no longer wander into an unrelated genre or
  decade. A station started from an artist could turn up something that
  merely sounded alike in tempo and texture — a rap station picking up
  1960s bossa nova, say — because that is all a server's own "similar"
  answer knows. Both radios now check genre and era the same way the
  "Made for You" mixes already did.

WORTH KNOWING

- Born on This Day sends a matched artist's MusicBrainz id to
  musicbrainz.org, in the background, only while the setting is on. See
  the App Description above.
- If a station you start now comes back noticeably shorter than it used
  to, that is the new genre/era check leaving too little to fill it —
  worth reporting if it happens often.

---

## 0.1.0 (430)

The artist choice from 429 now reaches Now Playing too.

FIXED

- On the playing screen, "Go to Artist" — in the "…" menu and by tapping
  the artist's name — now asks which artist on a song credited to two or
  more people, instead of always going to one of them. This is the same
  fix build 429 made for long-pressing a song in a list.

WORTH KNOWING

- Play a song with more than one name in its credit and try both: the
  "…" menu's "Go to Artist" and tapping the artist's name under the
  title. Both should offer a submenu.

---

## 0.1.0 (429)

A single fix: choosing an artist on a song credited to more than one.

FIXED

- "Go to Artist" asks which artist again on a song credited to two or more
  people. It had quietly stopped asking altogether, so a song listing
  "Artist A & Artist B" went straight to one of them no matter which
  artist's page, album or playlist you long-pressed it from.

WORTH KNOWING

- Long-press a song with more than one name in its credit, anywhere in the
  app, and "Go to Artist" should offer a submenu rather than a single
  destination.
- This was not something a recent build broke — it has likely never worked
  since the feature was added.

---

## 0.1.0 (428)

Fixes the crash on launch, and brings the background refresh and the iPad Now Playing with it.

FIXED

- The app no longer closes the moment it is opened, which it did on every device in builds 426 and 427.

NEW

- The app checks your server for new music without being opened, and syncs while the phone is charging if anything has changed.
- On iPad, the queue sits in a rail on the right of Now Playing, with History and Up Next.
- The chevron at the top of the rail folds it to a narrow strip, and the cover grows into the room it leaves. Tap the strip to open it again.
- Whether the rail starts open is remembered separately for landscape and portrait, and can be set in Settings › Now Playing.

CHANGED

- iPad always shows Now Playing framed, so the Layout and "Colour it like the stars" settings are gone there.

WORTH KNOWING

- The background refresh has nothing to turn on, and Offline Mode stops it. The sign it works is the sync spinner appearing less often.
- If Plevi ever opens on the Welcome screen when you already have a server, please report it, because that is the case this build guards against.
- In a window too narrow for the rail and the player side by side, such as Split View on an iPad mini or a small Stage Manager window, Now Playing uses the phone's arrangement.
- Nothing about Now Playing changes on iPhone.

---

## 0.1.0 (427)

Now Playing on iPad, with the queue beside the player.

NEW

- On iPad, the queue sits in a rail on the right of Now Playing, with History and Up Next.
- The chevron at the top of the rail folds it to a narrow strip, and the cover grows into the room it leaves. Tap the strip to open it again.
- Whether the rail starts open is remembered separately for landscape and portrait, and can be set in Settings › Now Playing.

CHANGED

- iPad always shows Now Playing framed, so the Layout setting is gone there.
- The "Colour it like the stars" setting is gone on iPad too, since it only affected the full-bleed layout.

WORTH KNOWING

- In a window too narrow for the rail and the player side by side, such as Split View on an iPad mini or a small Stage Manager window, Now Playing uses the phone's arrangement.
- Dragging a song in the open rail reorders it, and a drag down anywhere else still closes Now Playing.
- Nothing changes on iPhone.

---

## 0.1.0 (426)

The library refreshes itself in the background.

NEW

- The app now checks your server for new music without being opened, and
  syncs while the phone is charging if anything has changed.
- Opening the app should more often find the library already current,
  rather than starting a sync while you wait.

WORTH KNOWING

- There is nothing to turn on. Offline Mode still stops it, exactly as it
  stops a sync today.
- The check is one small request and is allowed on mobile data. The full
  sync only ever runs while charging, along with handing the library to
  a watch.
- iOS decides when these run and gives less to an app you rarely open.
  A phone that is seldom charged overnight may not see the sync job.
- This one is hard to observe on purpose. The sign it works is the sync
  spinner appearing less often than it used to.

---

## 0.1.0 (425)

Home rebuilt for a big screen. Almost all of this is iPad only.

NEW

- Editors' Choice is a two-column card on an iPad: the review beside a
  full-bleed sleeve, with the controls at the foot.
- Spotlight is a side-by-side pair instead of a poster stacked over a
  list.

CHANGED

- Editors' Choice shows the review itself rather than opening on a large
  quotation, and has room for about twice as much of it.
- The album's name sits directly under the date now, rather than at the
  foot of the card.

FIXED

- Editors' Choice appears on an iPad held upright. It only showed in
  landscape before.
- A long artist name is no longer cut off on that card.
- Released on This Day lines up on the left again after it rotates, with
  the cut-off album on the right.
- Spotlight's album list says whether it is ranked by your rating or the
  critic's, rather than always claiming it is yours.
- The large sleeve and the artist photograph no longer blink grey when
  you scroll back to them.
- Pressing either half of the Editors' Choice card now shrinks the whole
  card.

WORTH KNOWING

- Try both orientations, and Split View. Below about a third of a
  13-inch screen both shelves go back to the phone layout on purpose.
- A phone should look exactly as it did in 424.

---

## 0.1.0 (424)

Three DJ fixes, all reported from a device.

FIXED

- The DJ no longer queues the song that is already playing, where your
  library holds the same recording twice under credits written in
  opposite order.
- The DJ no longer inserts the same song every time. Moody and Drift
  now draw from what your server offers instead of always taking the
  nearest.
- Turning the DJ off and on now gives you something different. It was
  forgetting what it had just picked, then asking the same question
  again.

WORTH KNOWING

- Songs that sound nearest to what is playing are still much the most
  likely to be picked. They are no longer the only ones that can be.
- Turning a DJ off, listening a while, and turning it back on will
  still avoid what it picked earlier. That fades after about fifty
  songs.

---

## 0.1.0 (423)

Artist radio differs on every tap now, for every artist. Build 422 was
the same work unfinished and was never uploaded.

FIXED

- Artist radio gave the identical station on every tap for an artist
  with exactly four records in your library. Build 422 fixed this for
  one, two and three records and missed four entirely.
- A station could ask your server about the same recording twice, where
  a library holds one song on several records, wasting one of the four
  songs it starts from.

WORTH KNOWING

- Songs you rated well are still far more likely to start a station,
  and a song you marked down is unlikely rather than excluded.
- Song radio is improved but not fixed, as in 422. The song you
  long-pressed is its starting point and cannot change, and the similar
  songs come from your server, which gives the same answer each time.
- Artists with a handful of records are the clearest improvement.

---

## 0.1.0 (422)

Artist radio is a different station every time you ask for one.

CHANGED

- Artist radio no longer plays the identical queue on every tap. The
  songs it asks your server about are now drawn rather than always the
  same four.
- Songs you rated well are still far more likely to start a station, and
  a song you marked down is made unlikely rather than excluded.
- An artist with nothing rated now gets an even draw across their whole
  catalogue, which was the case that never varied at all.

FIXED

- An artist with only one record in your library was getting a station
  about a quarter of the usual length.

WORTH KNOWING

- Song radio is improved but not fixed. The song you long-pressed is its
  starting point and cannot change, and the similar songs come from your
  server, which gives the same answer each time. What varies is which of
  that artist's own songs are mixed in.
- Artists with two or three records in your library were the worst case
  and are the clearest improvement.

---

## 0.1.0 (421)

The app connects in about a second away from home, rather than three.

FIXED

- Starting the app, and starting a song, no longer pause for three
  seconds when you are away from your own network.
- The pause was the app asking whether your home address could be
  reached, and waiting far longer than it needed to for an answer that
  was never coming.

WORTH KNOWING

- At home you should notice no difference at all. The wait only ever
  elapsed when the home address genuinely was not there.
- Nothing is sent over the internet to make this decision, at home or
  anywhere else. That has not changed.
- The watch is deliberately left as it was, because everything it asks
  for relays through the phone and is slower by nature.

---

## 0.1.0 (420)

Sleeves appear as the app opens.

FIXED

- Album artwork already on the phone now appears immediately, instead of
  after a wait of up to three seconds on every cold start.
- Artwork now appears even when the server cannot be reached. A failed
  connection previously showed no sleeves at all for the whole session,
  over a cache already on the phone.

WORTH KNOWING

- The wait was longest away from home on mobile data, where the home
  address cannot answer and the check runs to its full timeout. On your
  own network you may never have seen it.
- That same three second wait still sits in front of everything else,
  playback included. It is the next build.

---

## 0.1.0 (419)

Radio plays the artist you started it from, and a new way through
everything you have not rated. Build 418 was the same work and was
never uploaded.

NEW

- Play Unrated, on an artist's long-press menu: shuffles every song by
  that artist nobody has rated yet.

CHANGED

- A radio started from a song or from an artist now includes songs by
  that artist, instead of leaving them out entirely.
- How many of its own artist a station carries follows Smart Shuffle's
  artist spacing, so a wider gap gives fewer and a narrower gap gives
  more.
- Song radio starts faster, because the artist's catalogue is now
  fetched alongside the similar songs rather than after them.

FIXED

- A radio started from a track on a various-artists compilation starts
  promptly, instead of reading every compilation on the server first.
- A song credited "someone feat. someone else" gets its own artist's
  songs in the station, rather than none of them.
- An artist's station can no longer play the same recording twice.
- "No similar songs found" appears immediately again, rather than after
  a wait.
- A narrow "Same artist" setting now spreads the artist through the
  whole station rather than its opening stretch.
- The song you started a radio from can no longer appear inside it.
- A song held on several records is no longer picked once per record.
- Unrated songs now rank above ones you rated one or two stars, rather
  than below them.

WORTH KNOWING

- The share is the thing to listen for, and Smart Shuffle's artist
  spacing is the dial if it sounds wrong in either direction.

---

## 0.1.0 (417)

Search works on an iPad again.

FIXED

- iPad: tapping Search now opens a search field and keyboard. It had
  raised nothing at all since build 407.

WORTH KNOWING

- On an iPad it takes two taps: Search opens the page, then the search
  button in it opens the keyboard. On a phone it is still one.

---

## 0.1.0 (416)

The cause of the playback stall, found and fixed.

FIXED

- Playback: songs no longer stop starting altogether after skipping
  around, which previously needed a force quit to clear.
- Playback: a song that never arrives now gives up after 45 seconds and
  says so, instead of waiting silently.

---

## 0.1.0 (413)

A further improvement on the stall from 412, from a second real log.

FIXED

- Playback: a skip now genuinely cancels the network request the skip
  before it was still waiting on, instead of leaving it running in the
  background to compete with the one you actually want.

---

## 0.1.0 (412)

Follow-up to build 411: the actual cause of the stall, found from a real log.

FIXED

- Playback: a song's fetch that goes completely silent now gives up after 45
  seconds with an error, instead of possibly waiting forever.

---

## 0.1.0 (411)

A playback stall fixed, and a layout bug on iPad.

FIXED

- Playback: skipping through songs quickly, back and forth, could eventually
  stop the player from starting another song.
- Playback: a dropped connection mid-song is retried again instead of ending
  the track early.
- iPad: album and artist covers no longer overflow the screen after
  rotating from landscape to portrait.

NEW

- Settings → Recent Problems has a "Copy playback log" button, for
  reporting anything that still goes wrong.

---

## What to Test — build 275

Paste as plain text. App Store Connect does not render Markdown in this field.

---

A small build: one new shortcut, and one radio behaving more like its name
says.

NEW

- Long-press a song on an album or in a playlist and tap Shuffle: it plays
  that song, then shuffles everything else around it. Three steps — tap the
  song, open Now Playing, tap Shuffle — down to one.

CHANGED

- Highly Rated radio now means 3 stars and up, not 2.5. It was quietly using
  the same floor every other radio uses just to decide what is not obviously
  disliked — a song you rated 2.5 counted as "highly rated," which the name
  did not really back up. Library Radio, Deep Cuts, Decades and Genres are
  unchanged.

---

## What to Test — build 274

Paste as plain text. App Store Connect does not render Markdown in this field.

---

Library, Albums and Artists are noticeably faster to open, especially on a
return visit. A menu bug and a long-press feature request also made it in.

FIXED

- Downloads: Stop now actually stops a song still waiting on the server's
  answer, rather than downloading it anyway a moment later. Raising "Songs at
  once" mid-download takes effect immediately instead of waiting for
  whatever is already running to finish on its own.
- The three-dot menu on a playlist had icons rendered nearly invisible — a
  tint meant for the button's own circle was leaking into the menu it opened.
  Fixed there and in one other menu with the same problem.
- Tapping Stop or "Go to Album"/"Go to Artist" from inside the full-screen
  player now closes it on the same slide a drag down does, instead of
  snapping shut instantly.
- A rare case where a song download could silently save a broken file and
  mark it done is now caught and fails properly instead.

NEW

- Long-pressing a song in a playlist now offers Go to Album and Go to Artist.
- Every song's long-press menu — Songs, Playlists, Downloads, search results
  — now groups Play/Radio and Play Next/Add to Queue into rows of icons, the
  same way an album's or an artist's menu already did. Same for a mix card's
  Play/Shuffle. The point is muscle memory: reaching for the same place in
  the menu whatever it was opened on.

FASTER

- Library ▸ Albums: a full read of the album table down by more than half,
  the A–Z jump bar no longer files itself on the frame you are looking at,
  and the page is kept between visits — going back in is instant and keeps
  the sort you left it on.
- Library ▸ Artists gets the same treatment. Smaller list, smaller win, but
  going back in is free either way.
- The mini-player now actually slides up into the full player — it was
  quietly skipping its own opening animation before.

---

## What to Test — build 273

Paste as plain text. App Store Connect does not render Markdown in this field.

---

A short build with one thing in it: the download setting that did nothing now
does what it says.

NEW

- "Songs at once", under Settings > Storage > Downloads. Choose how many songs
  download at the same time, or leave it on Automatic. The last run is timed
  underneath it, in songs a minute, so two settings can be compared rather than
  guessed at.

FIXED

- Downloads ran six at a time whatever was chosen. The number was being asked of
  iOS rather than kept by the app, and iOS answers six. The app holds the songs
  back itself now, and a change takes effect at once, including on a download
  already under way.
- Holding an album lifts the sleeve on its own. The title and artist used to be
  lifted with it and came up clipped and half-transparent.

WORTH A LOOK

- Change "Songs at once" while a download is running, and watch it take hold
  without restarting anything.
- Force-quit part way through a batch and open the app again. Transfers iOS
  carried on in the background are counted now, so the number should still hold
  rather than jumping to eight or stalling.
- Higher is not always faster. If downloads are set to convert, the server does
  real work for every song, and six at once is how an album arrives as two songs
  and a row of failures. The timing line is there to settle it.

---

## What to Test — build 272

Paste as plain text. App Store Connect does not render Markdown in this field.

---

A new home section picks one well-reviewed record a day, decade radios now go by
when the music was actually made, pulling the player down no longer mangles the
sleeve, and the Downloads screen has had a hard look at.

NEW

- Editors' Choice, on Home. One well-reviewed album a day, with the critic's
  score, an excerpt of the review, and five more by the same artist under it.
  It turns over at midnight and holds for the day. Plex only: the Subsonic API
  has no critic rating, so a Navidrome library gets no section rather than your
  own five-star albums under a name that claims otherwise.

CHANGED

- Made for You is a rolling shelf. A new mix joins the front every other day and
  ten are kept, instead of the same five names all week. A mix you liked is
  still there for the best part of three weeks.
- Decade radios go by when the music was made rather than when the copy was
  pressed. A 2011 collection of seventies soul now plays on the 1970s station,
  and a reissue plays in the decade it was recorded. A song nothing can place is
  left out rather than guessed at.
- Nothing rated below two and a half stars plays on any radio. Unrated songs
  still do.
- Mixes mind the decade as well as the genre, so a shared "Pop/Rock" tag no
  longer puts 1961 Elvis Presley beside 2019 Miley Cyrus.
- Library → Albums has the A–Z jump bar, in list mode.
- Shuffle and repeat are tinted rather than sitting on a filled circle, which
  was unreadable on a page coloured by the sleeve.
- Downloads can be sorted — each shelf its own way, both directions.
- Browsing from the Downloads tab shows only what is on the phone.
- A record kept as AAC says AAC, not the FLAC the server holds.
- A part-downloaded record offers both finishing it and removing it.
- Press-and-hold menus fit on one screen, and lift the sleeve rather than the
  whole card.

FIXED

- **Pulling the now-playing screen down cropped the artwork and then popped**,
  on the full-bleed layout. The card holds a list, and a list re-works its own
  insets as it moves through the safe area. The drag now carries a picture of
  the card rather than the card, which has nothing to re-work.
- The sleeve stretches when you pull it rather than leaving a gap above.
- A compilation track has a way through to its own artist instead of "Various
  Artists".
- Tapping a song in an artist's Popular section queues the whole chart, not just
  the ten on screen.
- Released on This Day and Radio reveal smoothly when scrolled back to from
  below, instead of snapping to full height.
- Artist mixes wear the artist's own picture again, not a record sleeve.
- The Downloads screen no longer crawls while a batch is being fetched, and the
  list is in the order things will actually arrive rather than alphabetical.

WORTH A CLOSE LOOK

- **Editors' Choice, over several days.** Does it hold still for a whole day,
  and does it change to something genuinely different tomorrow? It rotates
  genre and decade on purpose, so two jazz records in a row would be a bug.
- **A decade radio, if your library has compilations.** Ask for a decade you
  know you own on modern reissues and check the songs are actually from it.
- The now-playing drag on the full-bleed layout, released both slowly and with
  a flick.
- **Downloading a few hundred songs.** Scrolling should stay smooth throughout,
  including at the very start while they are being got ready.

KNOWN LIMITS

- Editors' Choice needs albums your Plex server has both a critic rating and
  review text for. If your library has none, the section will not appear — that
  is the data rather than the app.
- This build re-reads the library once on first launch, to pick up the new
  fields. Expect a sync on startup.
- **Library → Songs is still slow with a large library.** Not solved.
- The artist and album lines on the player still stop short of the sleeve's edge
  on long names.
- Playlists Plex builds from rules cannot be added to.
- Nothing here can delete anything on the server, by design.
- The Navidrome side has been read carefully but never run against a real
  Navidrome server.
- There is no CarPlay yet.

## What to Test — build 254

Paste as plain text. App Store Connect does not render Markdown in this field.

---

Songs start in half a second instead of six, mixes say who is in them, and the
silence before the end of a song is gone.

NEW

- Mixes name the artists they are made of, and are drawn with the artist's own
  face — or, for a genre, with four sleeves the way a playlist is.

CHANGED

- Released on This Day is one card rather than three, and says how long ago —
  "26 years ago" instead of the year and the record type. The setting that
  chose between the three kinds is gone.
- Recently Added and Recently Played hold fifty records rather than twelve.
  Rediscover holds fifteen, deliberately: fifty suggestions is a list.
- "See All" opens as rows, with a button for the grid, and remembers which you
  chose.
- The three transcoding rows say one word each: Wi-Fi, Cellular, Downloads.
- A fresh install now starts with the settings this app is actually used with
  rather than factory ones.
- The sleep timer is a plain moon; the framed player's sleeve sits a little
  higher.

FIXED

- **A song took up to six seconds to start.** The whole file was downloaded
  before a note played — a lossless track is twenty-five to thirty megabytes.
  It now starts on the first part of the file, measured at 0.43 seconds
  against 5.9. A Plex conversion always did this; an original never could.
- **About two seconds of silence roughly twelve seconds before the end of a
  song**, and worst with the longest overlap set. The end of each track is
  held back so a fade can be put into it, and the safety net that hands it
  over was set to fire two seconds too late.
- **A dropped connection ended the song.** Nothing retried anything, and
  pressing play did nothing because the engine was holding nothing to resume.
  Both fixed; the retry now waits about ten seconds before giving up, which is
  longer than the seven-second outage measured on the phone.
- A song being skipped after a transition — one ran into two, then jumped to
  three.
- A long song title was cut off before the edge of the sleeve.
- The artwork and the colour behind it now change on the same frame.
- The Now Playing card leaves the screen instead of hanging at the bottom.
- Mixes no longer put Kenny G in a video game soundtrack mix.

WORTH A CLOSE LOOK

- **A lossless track you have not played.** It should start almost at once —
  and more importantly it should play *through*. It is now read while it is
  still arriving, which is the kind of thing that fails on a slow connection
  rather than a fast one.
- The ends of songs, with the longest overlap set high.
- The company named on the mix cards: is it company you would want?
- Whether a dropped connection now recovers on its own.

KNOWN LIMITS

- **Library → Songs is still slow with a large library.** Two causes have been
  found and fixed and it is still not right. Not solved.
- If a join is decided late the outgoing song does not fade — it plays at its
  natural level under the one arriving.
- The artist and album lines on the player still stop short of the sleeve's
  edge on long names.
- Playlists Plex builds from rules cannot be added to.
- Nothing here can delete anything on the server, by design.
- The Navidrome side has been read carefully but never run against a real
  Navidrome server.
- There is no CarPlay yet.
