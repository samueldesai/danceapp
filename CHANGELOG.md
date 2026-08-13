# Changelog

## 1.2 — 13 August 2026

### Tempo detection

- **Dance Player can work out each song's BPM for you.** Turn it on in Advanced Settings or in
  the workbook import screen, or run it over a whole set at any time with **⌘B**. A progress bar
  shows how far along it is.
- **It uses the song's dance style to get the tempo right.** A lindy hop won't come back at half
  speed just because the music has a swing feel.
- Songs whose tempo changes on purpose — accelerating waltzes and the Romany Polka — are left
  alone rather than given a misleading number.
- Popular Edits ship with their published tempos, so Barbie Line Dance, the Bohemian National
  Polka and Tokyo Polka are always right.
- A tempo you type in yourself is never overwritten by detection.

### Set clock

- **A set clock in the toolbar** shows when your set is projected to finish and whether that's
  early or late, turning red once you're running over.
- Set your end time and your usual gap between songs. Jams and mixers are budgeted for
  automatically — 4 minutes for a jam, 1½ minutes for a mixer — so the estimate matches how a
  night actually runs.
- Open it from the toolbar or with **⌘⇧C**. It resets each time you launch the app.

### Audience screen

- **Jams get their own announcement**, with confetti, inviting the floor to come to the middle
  if they have something to celebrate.
- **Dance-with-a-stranger songs prompt the floor** to find someone they've never danced with.
- **The up-next list leads with the dance**, with the song title and artist underneath, and long
  names scroll instead of being cut off.
- The now-playing title and artist are larger and easier to read from the floor.
- Night Club Two Step is shown as **NC2S**.
- Closing dances are announced as "the last cross-step waltz" rather than "a last cross-step
  waltz".

### Cover art

- **A new Cover Art picker** (View menu, or Advanced Settings) walks your set song by song and
  offers high-resolution album art to choose from — up to 2000px, far beyond what Spotify
  provides. Nothing is replaced unless you pick it, and you can skip any song.
- Art for the next song loads while you're looking at the current one, so it's ready when you
  move on.
- Works for Spotify tracks as well as imported files.
- Chosen art is saved into your project at full resolution, so it only needs the internet once.

### Sound

- **A built-in compressor brings quiet songs up to level.** Some tracks are too quiet to reach
  the set's target volume without their peaks clipping — turning them up simply isn't possible.
  Dance Player now compresses those songs so they can sit alongside everything else instead of
  staying noticeably soft.
- The compressor runs **once, automatically, at import**, and only on the songs that actually
  need it. Everything else is left completely untouched.
- Compressed audio is saved **losslessly**, and your original file is never modified.
- **Changing a song's tempo re-checks its level**, so a sped-up track can't distort.

### Set guidelines

- The west coast swing tempo range is now 90–110 BPM.

### Working in the app

- **Undo (⌘Z)** for moving, removing, skipping and editing songs, naming the action it will undo.
- Dragging a song shows the whole row rather than a small box, with a proper grab cursor.
- Closing the window saves and closes your project, so reopening the app brings you back to the
  welcome screen.
- Double-clicking a `.dbdj` file opens that project.
- Turn on BPM detection right from the workbook import screen.
- Opening a project shows a progress bar with the song count.

### Everything else

Numerous bug fixes and performance improvements, including to saving, project loading, window
resizing and playback.

---

## 1.1.1 — 10 August 2026

### Workbook import

- **Style tags are read far more forgivingly.** "Cross-Step with a Stranger", "Rotary (jam)" and
  "Cross-step/Stranger" are all understood, so songs stop landing under "Other".
- **The closing dances are tagged for you** — the final west coast swing, lindy hop, cross-step
  waltz and rotary waltz are marked as the last of each.

### Set guidelines

- A cross-step waltz mixer now counts toward **both** the mixer and the cross-step waltz
  requirements.
- Songs marked as a jam or a dance with a stranger still count toward their dance style.
- "Last …" closing dances count toward their style's requirement.

### Working in the app

- **The queue and library split is resizable** and remembers where you left it.
- The now-playing text in the bottom bar is larger and no longer scrolls past you.

### Everything else

Bug fixes and performance improvements, including to saving.
