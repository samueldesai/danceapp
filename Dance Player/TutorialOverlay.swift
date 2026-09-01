//
//  TutorialOverlay.swift
//  Dance Player
//

import SwiftUI
import AppKit
import Combine
import AVFoundation
import CryptoKit

/// Fake sample tracks shown in the queue/library while the main control tour runs on an empty project.
@MainActor
final class TutorialSampleData: ObservableObject {
    static let shared = TutorialSampleData()

    private struct Sample {
        let title: String
        let artist: String
        let style: String
        /// Real playable audio for the "press play" step -- a track already bundled with the
        /// app rather than anything fetched over the network, so the tour works offline too.
        let audioResourceName: String
        let audioFileExtension: String

        var bundledAudioURL: URL? {
            Bundle.main.url(forResource: audioResourceName, withExtension: audioFileExtension, subdirectory: "audio files")
                ?? Bundle.main.url(forResource: audioResourceName, withExtension: audioFileExtension)
        }
    }

    // Title/artist match each file's own embedded metadata -- since these are real bundled
    // edits with real playable audio now, showing fictional names for them would just be
    // confusing (e.g. pressing play on "Echo" but hearing Dua Lipa).
    private static let samples: [Sample] = [
        Sample(title: "Dance The Night", artist: "Dua Lipa", style: "Barbie Line Dance",
               audioResourceName: "Barbie Line Dance", audioFileExtension: "mp3"),
        Sample(title: "Romany Polka", artist: "Richard Powers", style: "Romany Polka",
               audioResourceName: "Romany Polka", audioFileExtension: "mp3"),
        Sample(title: "Nadie Como Tu", artist: "Bachateros de Metal", style: "Bachata",
               audioResourceName: "Nadie Como Tu (Bachata Version)", audioFileExtension: "mp3"),
        Sample(title: "Feuerfest Polka, Op. 269", artist: "Johann Strauss II, Josef Strauss, Cincinnati Pops Orchestra & Erich Kunzel", style: "Bohemian National Polka",
               audioResourceName: "Bohemian National Polka", audioFileExtension: "mp3")
    ]

    /// The artwork-bearing cache -- never mutated by the demo itself.
    @Published private(set) var tracks: [Track]
    /// The queue and library views both bind straight to this, so a reorder/skip/delete/
    /// classify in one shows up in the other, the same way they'd share one real `player.tracks`.
    @Published var demoTracks: [Track] = []

    /// Same content hash `PlayerController.hashAudioFile` uses for a real import -- these are
    /// real bundled files, so there's no reason for their identity to be anything special.
    private static func hashAudioFile(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return UUID().uuidString }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 1024 * 1024)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private init() {
        tracks = Self.samples.map { sample in
            let url = sample.bundledAudioURL ?? URL(fileURLWithPath: "/")
            return Track(url: url, title: sample.title, artist: sample.artist,
                         danceStyles: [sample.style], duration: 180, songHash: Self.hashAudioFile(url))
        }
        demoTracks = tracks
        Task { await loadArtwork() }
    }

    /// A fresh copy of the first sample track, appended back when a deleted demo runs empty --
    /// there always needs to be at least one for the later steps (classify, play) to point at.
    func spareTrack() -> Track? {
        guard let first = tracks.first else { return nil }
        var spare = Track(url: first.url, title: first.title, artist: first.artist,
                           danceStyles: first.danceStyles, duration: first.duration, songHash: first.songHash)
        spare.artwork = first.artwork
        return spare
    }

    /// Reseeded every time the main control tour (re)starts, so a previous run's reordering,
    /// skips or deletions don't carry over into the next.
    func resetDemo() {
        demoTracks = tracks
    }


    func prepareClassificationTargetIfNeeded() {
        guard !demoTracks.isEmpty, !demoTracks.contains(where: { $0.danceStyles.isEmpty }) else { return }
        demoTracks[0].danceStyles = []
    }

    /// Pulled straight from each bundled file's own ID3 artwork -- same technique
    /// `PopularEditArtwork` uses -- rather than an iTunes lookup, since these are real local
    /// files with real embedded art now, no network needed.
    private func loadArtwork() async {
        for (index, sample) in Self.samples.enumerated() {
            guard tracks.indices.contains(index), let url = sample.bundledAudioURL else { continue }
            let id = tracks[index].id

            let asset = AVURLAsset(url: url)
            guard let metadata = try? await asset.load(.commonMetadata) else { continue }
            for item in metadata where item.commonKey == .commonKeyArtwork {
                guard let data = try? await item.load(.dataValue), let image = NSImage(data: data) else { continue }
                tracks[index].artwork = image
                if let demoIndex = demoTracks.firstIndex(where: { $0.id == id }) { demoTracks[demoIndex].artwork = image }
                break
            }
        }
    }
}

/// One of the app's tour-able surfaces; each tracks its own "have I shown this before" flag.
enum TutorialContext: String, CaseIterable {
    case mainControl
    case workbookImporter
    case timingEditor
    case spotifyImporter
    case songImporter

    fileprivate var seenDefaultsKey: String { "DancePlayer.tutorialSeen.\(rawValue)" }
}

/// A concrete thing the DJ has to actually do before a gated step's Next will advance.
enum TutorialAction: Equatable {
    case openedAddMenu
    case reorderedSample
    case hiddenSample
    case deletedSample
    case classifiedSample
    case pressedPlaySample
    case editorPlayed
    case editorTrimmed
    case editorBladed
    case editorMetadataEdited
    case editorTempoChanged
    case openedPopularEditsMenu
    case selectedPopularEdit
}

struct TutorialStep {
    /// Matches a `.tutorialAnchor(_:)` elsewhere in the tree. `nil` renders as a centered
    /// welcome/closing message with no spotlight cutout.
    let anchorID: String?
    /// Extra anchors also cut out of the scrim alongside `anchorID` -- for a step where the
    /// DJ needs to interact with more than one area (e.g. click the waveform, then a toolbar
    /// button elsewhere) to complete the required action.
    var additionalAnchorIDs: [String] = []
    let title: String
    let message: String
    /// When set, Next stays clickable but won't advance -- and the spotlight's cutout becomes
    /// interactive instead of just a see-through window -- until this action is reported.
    var requiredAction: TutorialAction? = nil
    /// Shown in place of the step's own message for a couple of seconds after a blocked Next
    /// click, e.g. "Click the plus button first."
    var lockedMessage: String? = nil
    /// Moves on by itself once `requiredAction` completes, instead of waiting for a Next click
    /// -- for a chain of steps living inside a native popover (Add Track's own menu, say),
    /// where a Next click lands outside that popover and closes it before the next step can
    /// point at anything inside it.
    var autoAdvances: Bool = false
    /// For a target that pops open a native/custom popover below itself -- placing the callout
    /// below would land it right on top of that popover, so this asks for beside instead.
    var calloutPrefersSide: Bool = false
}

private enum TutorialLibrary {
    static func steps(for context: TutorialContext) -> [TutorialStep] {
        switch context {
        case .mainControl: return mainControl
        case .workbookImporter: return workbookImporter
        case .timingEditor: return timingEditor
        case .spotifyImporter: return spotifyImporter
        case .songImporter: return songImporter
        }
    }

    static let mainControl: [TutorialStep] = [
        TutorialStep(
            anchorID: nil,
            title: "Welcome to Dance Player",
            message: "Here's a quick, hands-on tour of the main control view — the DJ booth where you build and run your set. A few steps will ask you to actually try something instead of just reading about it. Press Next to continue, or Skip to jump right in."
        ),
        TutorialStep(
            anchorID: "playlist.add",
            title: "Add A Track",
            message: "Add tracks from Spotify, YouTube, or local files here — you can also add popular edits like BNP or Romany Polka. Give it a click.",
            requiredAction: .openedAddMenu,
            lockedMessage: "Click the plus button first.",
            autoAdvances: true,
            calloutPrefersSide: true
        ),
        TutorialStep(
            anchorID: "addmenu.popularEdits",
            title: "Popular Edits",
            message: "Ready-to-play favorites already bundled with the app — BNP, Romany Polka, Dawn Mazurka and more. Try it: click Popular Edits.",
            requiredAction: .openedPopularEditsMenu,
            lockedMessage: "Click Popular Edits first.",
            autoAdvances: true,
            calloutPrefersSide: true
        ),
        TutorialStep(
            anchorID: "addmenu.editsList",
            title: "Pick An Edit",
            message: "Pick any edit to add it straight to your queue.",
            requiredAction: .selectedPopularEdit,
            lockedMessage: "Click one of the edits first.",
            autoAdvances: true,
            calloutPrefersSide: true
        ),
        TutorialStep(
            anchorID: "playlist.queue",
            title: "Reorder On The Fly",
            message: "Drag one sample track onto another to swap their order. You can do this while your set is still playing!",
            requiredAction: .reorderedSample,
            lockedMessage: "Drag one of the sample tracks onto another to reorder them first."
        ),
        TutorialStep(
            anchorID: "playlist.queue",
            title: "Hide A Track",
            message: "Right-click a track and choose Skip Track to hide it from the set without losing your place.",
            requiredAction: .hiddenSample,
            lockedMessage: "Right-click a sample track and choose Skip Track first."
        ),
        TutorialStep(
            anchorID: "playlist.queue",
            title: "Delete A Track",
            message: "Right-click a track and choose Delete Track to pull it out of the queue entirely.",
            requiredAction: .deletedSample,
            lockedMessage: "Right-click a sample track and choose Delete Track first."
        ),
        TutorialStep(
            anchorID: "library.rows",
            title: "Setlist (Large View)",
            message: "The main pane is where you set styles, edit songs, and can also reorder here too! Let's try setting a style for the first song by clicking on the ribbon below the artist.",
            requiredAction: .classifiedSample,
            lockedMessage: "Tap the \"Select Style\" box on the untagged song and choose a style first."
        ),
        TutorialStep(
            anchorID: "transport.controls",
            title: "Play",
            message: "You can play by clicking tracks in the main view, side queue, or up here at the top. Let's press play!",
            requiredAction: .pressedPlaySample,
            lockedMessage: "Press play first."
        ),
        TutorialStep(
            anchorID: "playback.status",
            title: "Now Playing",
            message: "Track progress, timing and levels for whatever's live show up down here — that's the track you just played."
        ),
        TutorialStep(
            anchorID: "setclock.bar",
            title: "Set Clock",
            message: "Configure a running countdown for your set here — handy for staying on schedule."
        ),
        TutorialStep(
            anchorID: "audience.button",
            title: "Audience Screen",
            message: "Open a second window with a clean now-playing display for the dance floor to see."
        ),
        TutorialStep(
            anchorID: nil,
            title: "Stuck? There's Always A Tutorial",
            message: "That's the tour. If you ever need a refresher, press Command-Shift-T on any screen to pull up the tutorial for whatever window you're looking at."
        )
    ]

    static let workbookImporter: [TutorialStep] = [
        TutorialStep(
            anchorID: nil,
            title: "Reviewing Your Workbook",
            message: "This is the Dancebreak DJ Workbook import review — check every row before bringing songs into your project."
        ),
        TutorialStep(
            anchorID: "workbook.header",
            title: "Project Name",
            message: "Confirm or edit the project's name here before importing."
        ),
        TutorialStep(
            anchorID: "workbook.rows",
            title: "Review Each Song",
            message: "Check the matched source, dance styles, BPM and tempo for every row, and fix anything that looks off before importing. If a YouTube match can't be found for some songs, you'll get a chance to try Spotify instead, rename and retry, or import them locally."
        ),
        TutorialStep(
            anchorID: "workbook.import",
            title: "Add Songs",
            message: "Happy with the matches? Click Add Songs to bring the remaining rows into your project — you'll be asked whether to pull them from Spotify or YouTube."
        ),
        TutorialStep(
            anchorID: "workbook.compliance",
            title: "Guideline Compliance",
            message: "Once everything's added, check compliance here to catch any songs that run long or break your event's rules."
        ),
        TutorialStep(
            anchorID: "workbook.finish",
            title: "Import Project",
            message: "When you're happy with everything, click Import Project to finish and head to the main control view."
        )
    ]

    static let timingEditor: [TutorialStep] = [
        TutorialStep(
            anchorID: nil,
            title: "The Track Editor",
            message: "Trim, fade and fine-tune any track here before it plays live. A few steps will have you actually try something — nothing you do during this tour is kept, so feel free to experiment."
        ),
        TutorialStep(
            anchorID: "editor.footer",
            title: "Press Play",
            message: "Give it a listen first — press Play from Playhead down here to hear the track exactly as it'll play live.",
            requiredAction: .editorPlayed,
            lockedMessage: "Press Play from Playhead first."
        ),
        TutorialStep(
            anchorID: "editor.metadata",
            title: "Title, Artist & Art",
            message: "Edit the track's title, artist and cover art here. Try it: change the title or artist to anything.",
            requiredAction: .editorMetadataEdited,
            lockedMessage: "Change the title or artist field first."
        ),
        TutorialStep(
            anchorID: "editor.tempo",
            title: "Tempo Warp",
            message: "Speed a track up or down without changing its pitch. Try it: drag the tempo slider a bit.",
            requiredAction: .editorTempoChanged,
            lockedMessage: "Drag the tempo slider first."
        ),
        TutorialStep(
            anchorID: "editor.waveform",
            title: "The Waveform",
            message: "Drag the start or end handle to trim the track, and the diamond handles to set the fade in and out. Try it: drag either edge handle a bit.",
            requiredAction: .editorTrimmed,
            lockedMessage: "Drag the start or end handle first."
        ),
        TutorialStep(
            anchorID: "editor.zoom",
            additionalAnchorIDs: ["editor.waveform"],
            title: "Zoom & Blade",
            message: "Zoom in for precise edits, or fit the whole waveform back on screen. Try it: click somewhere in the middle of the waveform to drop the playhead there, then press Command-B (or click Blade) to split the track right at that point.",
            requiredAction: .editorBladed,
            lockedMessage: "Click the waveform to move the playhead, then blade the track with Command-B or the Blade button."
        ),
        TutorialStep(
            anchorID: "editor.boundary",
            title: "Start & End",
            message: "Type exact timestamps for the start and end of the track here."
        ),
        TutorialStep(
            anchorID: "editor.fade",
            title: "Fades",
            message: "Set precise fade-in and fade-out durations here."
        ),
        TutorialStep(
            anchorID: "editor.footer",
            title: "Export & Done",
            message: "Export a standalone file if you'd like a copy, or hit Done to apply your changes back to the queue."
        )
    ]

    /// Covers both track and playlist import -- same sheet, same anchors, just a different
    /// input field depending on which one the DJ opened.
    static let spotifyImporter: [TutorialStep] = [
        TutorialStep(
            anchorID: nil,
            title: "Importing From Spotify",
            message: "Bring in a single track or a whole playlist straight from Spotify."
        ),
        TutorialStep(
            anchorID: "spotify.clientID",
            title: "Spotify Client ID",
            message: "Needed once per machine to talk to Spotify. Tap the ? for help finding yours."
        ),
        TutorialStep(
            anchorID: "spotify.input",
            title: "Track Or Playlist",
            message: "Paste a link, URI, or ID here — or for a single track, just type the artist and song title."
        ),
        TutorialStep(
            anchorID: "spotify.actions",
            title: "Search & Import",
            message: "Search to review matches first, or import directly if you already know it's right."
        )
    ]

    static let songImporter: [TutorialStep] = [
        TutorialStep(
            anchorID: nil,
            title: "Download A Song",
            message: "A plain YouTube search-and-download — no Spotify account or API key needed."
        ),
        TutorialStep(
            anchorID: "song.search",
            title: "Search",
            message: "Type whatever you'd type into YouTube's own search box, then pick the right match below."
        ),
        TutorialStep(
            anchorID: "song.results",
            title: "Pick A Match",
            message: "Its audio downloads from YouTube, with the title, artist and cover art filled in from iTunes."
        )
    ]
}

/// Drives the tour: which context (if any) is active, and which step of it is showing.
final class TutorialManager: ObservableObject {
    static let shared = TutorialManager()
    private init() {}

    @Published private(set) var activeContext: TutorialContext?
    @Published private(set) var stepIndex: Int = 0

    /// Whether the current step's `requiredAction` (if it has one) has been reported yet --
    /// reset every time the step changes.
    @Published private(set) var isActionComplete = false
    /// A step's `lockedMessage`, shown briefly in place of its normal message after a Next
    /// click that couldn't advance -- cleared automatically after a couple of seconds.
    @Published private(set) var lockedFeedback: String?
    /// Drives the purple confetti burst when a gated step's action just got reported.
    @Published private(set) var isCelebrating = false
    /// Set when the "press play" sample step's action fires, so the (otherwise real,
    /// player-state-driven) Now Playing step has something to show that matches whichever
    /// sample the DJ actually pressed play on.
    @Published private(set) var simulatedNowPlaying: (title: String, artist: String)?
    /// Whether a sample's downloaded audio is actually playing right now -- drives the
    /// transport bar's icon during the tour the same way `player.isPlaying` does normally.
    @Published private(set) var isSamplePlaying = false

    private var lockedFeedbackTask: Task<Void, Never>?
    private var celebrationTask: Task<Void, Never>?
    private var sampleAudioPlayer: AVAudioPlayer?
    private var samplePlayingTrackID: UUID?

    /// Set by the New Project dialog's "Run tutorial after creating" checkbox -- when the new
    /// project also imports a workbook, that queues *both* `.workbookImporter` and
    /// `.mainControl`, since the workbook review appears first and `QueueSplitView` (where the
    /// main control tour's anchors actually live) doesn't appear until that review is
    /// dismissed. A set, not a single value, so both survive even though only one of their
    /// views is on screen at a time. Each entry is consumed by `startIfNeverSeen` once its own
    /// view actually appears, overriding whatever "already seen" flag that context has.
    private var pendingAutoStart: Set<TutorialContext> = []

    var steps: [TutorialStep] {
        guard let activeContext else { return [] }
        return TutorialLibrary.steps(for: activeContext)
    }

    var currentStep: TutorialStep? {
        steps.indices.contains(stepIndex) ? steps[stepIndex] : nil
    }

    /// Explicit start -- from the Command-Shift-T shortcut, or a "Run Tutorial" checkbox.
    func start(_ context: TutorialContext) {
        activeContext = context
        stepIndex = 0
        isActionComplete = false
        simulatedNowPlaying = nil
        stopSamplePlayback()
        if context == .mainControl { TutorialSampleData.shared.resetDemo() }
    }

    func simulatePlaying(title: String, artist: String) {
        simulatedNowPlaying = (title, artist)
    }

    /// (Re)starts real playback of a sample's downloaded audio -- used by both the queue's
    /// double-click-to-play and the transport bar's Play button, so either entry point reports
    /// the same gated action. The tour has to complete offline too, so this never *requires*
    /// that download to have succeeded: real audio plays when it's there, and either way the
    /// simulated Now Playing bar and the gated action fire exactly as they did before real
    /// playback existed.
    func playSample(_ track: Track) {
        if samplePlayingTrackID != track.id || sampleAudioPlayer == nil {
            sampleAudioPlayer = try? AVAudioPlayer(contentsOf: track.url)
            sampleAudioPlayer?.prepareToPlay()
            samplePlayingTrackID = track.id
        }
        isSamplePlaying = sampleAudioPlayer?.play() ?? false
        simulatePlaying(title: track.title, artist: track.artist)
        reportAction(.pressedPlaySample)
    }

    /// The transport bar's Play button toggles: pause if this sample is the one already
    /// playing, otherwise (re)start it -- matching how the real transport's button behaves.
    func toggleSamplePlayback(_ track: Track) {
        if isSamplePlaying, samplePlayingTrackID == track.id {
            sampleAudioPlayer?.pause()
            isSamplePlaying = false
        } else {
            playSample(track)
        }
    }

    private func stopSamplePlayback() {
        sampleAudioPlayer?.stop()
        sampleAudioPlayer = nil
        samplePlayingTrackID = nil
        isSamplePlaying = false
    }

    /// Queues a tour to force-start the next time `context`'s view appears, rather than right
    /// now -- see `pendingAutoStart` for why, and note it deliberately ignores the "already
    /// seen" flag, since the whole point is letting the checkbox re-run a tour that's been seen
    /// before.
    func scheduleStart(_ context: TutorialContext) {
        pendingAutoStart.insert(context)
    }

    /// Called from each toured view's `onAppear`. Runs the tour exactly once per context,
    /// ever, unless something else (the New Project dialog's checkbox) already decided.
    func startIfNeverSeen(_ context: TutorialContext) {
        if pendingAutoStart.contains(context) {
            pendingAutoStart.remove(context)
            markSeen(context)
            start(context)
            return
        }
        guard !UserDefaults.standard.bool(forKey: context.seenDefaultsKey) else { return }
        markSeen(context)
        start(context)
    }

    func markSeen(_ context: TutorialContext) {
        UserDefaults.standard.set(true, forKey: context.seenDefaultsKey)
    }

    /// Reports that a step's required action just happened -- a no-op unless it matches the
    /// *current* step's own `requiredAction`, so a stray call from a view that isn't the one on
    /// screen right now (or a step the DJ has already moved past) can't light up the wrong gate.
    func reportAction(_ action: TutorialAction) {
        guard let step = currentStep, step.requiredAction == action, !isActionComplete else { return }
        isActionComplete = true
        celebrate()
        if step.autoAdvances {
            let stepAtReport = stepIndex
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled, stepIndex == stepAtReport else { return }
                advance()
            }
        }
    }

    private func celebrate() {
        celebrationTask?.cancel()
        isCelebrating = true
        celebrationTask = Task {
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            isCelebrating = false
        }
    }

    /// Blocked (rather than simply disabled) so a click always does *something* -- the DJ sees
    /// exactly why nothing happened instead of just a Next button that doesn't seem to work.
    private func rejectAdvance() {
        guard let message = currentStep?.lockedMessage else { return }
        lockedFeedbackTask?.cancel()
        lockedFeedback = message
        lockedFeedbackTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            lockedFeedback = nil
        }
    }

    func advance() {
        guard let activeContext else { return }
        guard currentStep?.requiredAction == nil || isActionComplete else {
            rejectAdvance()
            return
        }
        if stepIndex + 1 < TutorialLibrary.steps(for: activeContext).count {
            stepIndex += 1
            isActionComplete = false
            lockedFeedback = nil
            prepareCurrentStepIfNeeded()
        } else {
            finish()
        }
    }

    func back() {
        stepIndex = max(0, stepIndex - 1)
        isActionComplete = false
        lockedFeedback = nil
        prepareCurrentStepIfNeeded()
    }

    private func prepareCurrentStepIfNeeded() {
        if currentStep?.requiredAction == .classifiedSample {
            TutorialSampleData.shared.prepareClassificationTargetIfNeeded()
        }
    }

    func finish() {
        activeContext = nil
        stepIndex = 0
        isActionComplete = false
        lockedFeedback = nil
        simulatedNowPlaying = nil
        stopSamplePlayback()
    }
}

/// The named coordinate space every `.tutorialAnchor` frame is measured in, established by whichever `TutorialOverlayHost` is the nearest ancestor.
enum TutorialCoordinateSpace {
    static let name = "tutorialOverlay"
}

/// Collects every tagged view's frame (in `TutorialCoordinateSpace`) so the host can cut a hole in the scrim around it.
private struct TutorialFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as a stop on the tour, addressable from a `TutorialStep.anchorID`. Measures via a background `GeometryReader` into a named coordinate space rather than `.anchorPreference`, which silently dropped several anchors (buttons and a conditional `Group` among them) in practice.
    func tutorialAnchor(_ id: String) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TutorialFramePreferenceKey.self,
                    value: [id: geo.frame(in: .named(TutorialCoordinateSpace.name))]
                )
            }
        )
    }
}

/// Full-screen scrim with a rounded-rect hole punched out around `hole` (or none, for intro/closing steps).
private struct SpotlightMaskShape: Shape {
    var hole: CGRect?

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole {
            path.addPath(Path(roundedRect: hole.insetBy(dx: -8, dy: -8), cornerRadius: 10))
        }
        return path
    }
}

/// The title/message/step-counter/Back-Skip-Next card, hostable inline or in `TutorialCalloutPanel`.
struct TutorialCalloutView: View {
    let step: TutorialStep

    @ObservedObject private var manager = TutorialManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            if let lockedFeedback = manager.lockedFeedback {
                Text(lockedFeedback)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#eab308"))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            } else {
                Text(step.message)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#d4d4d8"))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if step.requiredAction != nil, !manager.isActionComplete {
                Label("Try it in the app to continue", systemImage: "hand.point.up.left.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#3478f6"))
            }

            HStack(spacing: 10) {
                Text("Step \(manager.stepIndex + 1) of \(manager.steps.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#71717a"))

                Spacer()

                Button("Skip") { manager.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .pointingHandCursor()

                if manager.stepIndex > 0 {
                    Button("Back") { manager.back() }
                        .buttonStyle(.bordered)
                        .pointingHandCursor()
                }

                Button(manager.stepIndex + 1 == manager.steps.count ? "Done" : "Next") {
                    manager.advance()
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .background(Color(hex: "#18181c"))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: "#2f2f38"), lineWidth: 1))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
        .animation(.easeInOut(duration: 0.2), value: manager.lockedFeedback)
    }
}

/// A quick purple confetti burst with "NICE" scaling in, shown when a gated step's action completes.
struct TutorialCelebrationView: View {
    @State private var hasAppeared = false

    private static let confettiColors: [Color] = [
        Color(hex: "#22c55e"), Color(hex: "#4ade80"), Color(hex: "#15803d"),
        Color(hex: "#86efac"), Color(hex: "#16a34a")
    ]

    private struct Particle: Identifiable {
        let id = Int.random(in: Int.min...Int.max)
        let angle: Double
        let distance: CGFloat
        let color: Color
        let size: CGFloat
        let spin: Double
    }

    private let particles: [Particle] = (0..<44).map { _ in
        Particle(
            angle: Double.random(in: 0..<360),
            distance: CGFloat.random(in: 100...260),
            color: confettiColors.randomElement()!,
            size: CGFloat.random(in: 9...18),
            spin: Double.random(in: -180...180)
        )
    }

    var body: some View {
        ZStack {
            ForEach(particles) { particle in
                RoundedRectangle(cornerRadius: 2)
                    .fill(particle.color)
                    .frame(width: particle.size, height: particle.size * 0.6)
                    .rotationEffect(.degrees(hasAppeared ? particle.spin : 0))
                    .offset(
                        x: hasAppeared ? cos(particle.angle * .pi / 180) * particle.distance : 0,
                        y: hasAppeared ? sin(particle.angle * .pi / 180) * particle.distance : 0
                    )
                    .opacity(hasAppeared ? 0 : 1)
            }

            Text("NICE")
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundColor(Color(hex: "#4ade80"))
                .shadow(color: Color(hex: "#15803d").opacity(0.8), radius: 18)
                .scaleEffect(hasAppeared ? 1 : 0.4)
                .opacity(hasAppeared ? 1 : 0)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 1.0)) { hasAppeared = true }
        }
    }
}

/// Stands in for `PlaybackStatusBar` while the tour's fake sample tracks have "played" instead.
struct TutorialSimulatedNowPlayingBar: View {
    let title: String
    let artist: String

    @ObservedObject private var tutorialSampleData = TutorialSampleData.shared
    @State private var pulse = false

    private var artwork: NSImage? {
        tutorialSampleData.demoTracks.first { $0.title == title }?.artwork
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color(hex: "#1c1c22")
                        Image(systemName: "music.note").foregroundColor(Color(hex: "#44444a"))
                    }
                }
            }
            .frame(width: 44, height: 44)
            .cornerRadius(4)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#3478f6"))
                        .opacity(pulse ? 1 : 0.4)
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(artist)
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#a3a3ac"))
            }

            Spacer()
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct TutorialStepView: View {
    let step: TutorialStep
    let frames: [String: CGRect]
    let containerSize: CGSize
    /// False while a small window's callout is living in `TutorialCalloutPanel` instead --
    /// the spotlight and cutout still render here either way.
    var showsInlineCallout: Bool = true

    /// Every anchor this step points at -- usually one, but a step that needs the DJ to
    /// interact with two separate areas (the waveform, then a toolbar button elsewhere) lists
    /// more via `additionalAnchorIDs`.
    private var targetRects: [CGRect] {
        ([step.anchorID].compactMap { $0 } + step.additionalAnchorIDs).compactMap { frames[$0] }
    }

    /// The bounding box of every target, used for the scrim's single cutout and click-through
    /// hole -- simpler than punching one hole per rect, and harmless for this app's steps since
    /// their multiple targets are always adjacent, not scattered across the screen.
    private var combinedTarget: CGRect? {
        targetRects.dropFirst().reduce(targetRects.first) { $0?.union($1) }
    }

    @ObservedObject private var manager = TutorialManager.shared

    /// A gated step needs the DJ to actually reach the real button underneath its cutout.
    private var isInteractive: Bool { step.requiredAction != nil }

    var body: some View {
        let target = combinedTarget

        ZStack {
            if let target, isInteractive {
                interactiveScrim(around: target)
            } else {
                SpotlightMaskShape(hole: target)
                    .fill(Color.black.opacity(0.68), style: FillStyle(eoFill: true))
                    .allowsHitTesting(true)
            }

            ForEach(Array(targetRects.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(hex: "#3478f6"), lineWidth: 2)
                    .frame(width: rect.width + 16, height: rect.height + 16)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            if showsInlineCallout {
                TutorialCalloutView(step: step)
                    .position(calloutPosition(target: targetRects.first, preferSide: step.calloutPrefersSide))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: step.anchorID)
    }

    /// Four plain opaque rectangles tiling everything except `hole`'s padded bounds, rather than
    /// one shape with a hole cut via an even-odd fill rule -- a plain rectangle's hit-testing is
    /// unambiguous, where a `Shape`'s even-odd content shape passing clicks through its hole is a
    /// subtler contract this needed to not depend on.
    private func interactiveScrim(around hole: CGRect) -> some View {
        let padded = hole.insetBy(dx: -8, dy: -8)
        let top = max(0, padded.minY)
        let bottom = max(0, containerSize.height - padded.maxY)
        let left = max(0, padded.minX)
        let right = max(0, containerSize.width - padded.maxX)
        let scrim = Color.black.opacity(0.68)

        return VStack(spacing: 0) {
            scrim.frame(height: top)
            HStack(spacing: 0) {
                scrim.frame(width: left)
                Color.clear.frame(width: padded.width).allowsHitTesting(false)
                scrim.frame(width: right)
            }
            .frame(height: padded.height)
            scrim.frame(height: bottom)
        }
        .frame(width: containerSize.width, height: containerSize.height)
    }

    /// Below the target if there's room, else above it, else just off-center -- there's no
    /// live measurement of the callout's actual (text-dependent) height, so this leans on a
    /// generous estimate rather than measuring, to keep it out of the target's own cutout.
    private func calloutPosition(target: CGRect?, preferSide: Bool = false) -> CGPoint {
        let calloutWidth: CGFloat = 300
        let estimatedHeight: CGFloat = 190
        let margin: CGFloat = 20

        guard let target else {
            return CGPoint(x: containerSize.width / 2, y: containerSize.height / 2)
        }

        if preferSide {
            let spaceRight = containerSize.width - target.maxX
            let spaceLeft = target.minX
            let y = min(
                max(target.midY, estimatedHeight / 2 + margin),
                max(estimatedHeight / 2 + margin, containerSize.height - estimatedHeight / 2 - margin)
            )
            if spaceRight >= calloutWidth + margin {
                return CGPoint(x: target.maxX + margin + calloutWidth / 2, y: y)
            } else if spaceLeft >= calloutWidth + margin {
                return CGPoint(x: target.minX - margin - calloutWidth / 2, y: y)
            }
            // Not enough room on either side -- fall through to the below/above logic.
        }

        let x = min(
            max(target.midX, calloutWidth / 2 + margin),
            max(calloutWidth / 2 + margin, containerSize.width - calloutWidth / 2 - margin)
        )

        let spaceBelow = containerSize.height - target.maxY
        let spaceAbove = target.minY
        let y: CGFloat
        if spaceBelow >= estimatedHeight + margin {
            y = target.maxY + margin + estimatedHeight / 2
        } else if spaceAbove >= estimatedHeight + margin {
            y = target.minY - margin - estimatedHeight / 2
        } else {
            y = min(
                max(containerSize.height / 2, estimatedHeight / 2 + margin),
                max(estimatedHeight / 2 + margin, containerSize.height - estimatedHeight / 2 - margin)
            )
        }
        return CGPoint(x: x, y: y)
    }
}

/// Reports the hosting `NSWindow`, used to size-gate and position `TutorialCalloutPanel`.
private struct TutorialWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// A borderless, floating panel for the tutorial callout, used beside a window too small to fit one inline.
private final class TutorialCalloutPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    }

    override var canBecomeKey: Bool { true }
}

/// Shared by every `TutorialOverlayHost`; ownership-gated via `shownForContext` so an inactive host's hide can't race the active host's show.
@MainActor
private final class TutorialCalloutPanelController {
    static let shared = TutorialCalloutPanelController()
    private var panel: TutorialCalloutPanel?
    private var shownForContext: TutorialContext?

    func show(_ step: TutorialStep, for context: TutorialContext, besideWindow window: NSWindow) {
        shownForContext = context

        let panel = self.panel ?? TutorialCalloutPanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: TutorialCalloutView(step: step).preferredColorScheme(.dark)
        )

        let size = panel.contentView?.fittingSize ?? NSSize(width: 300, height: 220)
        panel.setContentSize(size)

        let windowFrame = window.frame
        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? windowFrame
        let margin: CGFloat = 20
        var origin = NSPoint(x: windowFrame.maxX + margin, y: windowFrame.maxY - size.height)

        // Not enough room to the right -- try the left instead, then just below as a last resort.
        if origin.x + size.width > screenFrame.maxX {
            origin.x = windowFrame.minX - size.width - margin
        }
        if origin.x < screenFrame.minX {
            origin = NSPoint(
                x: windowFrame.minX + (windowFrame.width - size.width) / 2,
                y: windowFrame.minY - size.height - margin
            )
        }
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func hideIfShowing(for contexts: Set<TutorialContext>) {
        guard let shownForContext, contexts.contains(shownForContext) else { return }
        panel?.orderOut(nil)
        self.shownForContext = nil
    }
}

/// A separate, larger floating panel for the confetti burst -- big enough to read from across
/// the window instead of squeezed into whatever's left around a small spotlight cutout.
private final class TutorialCelebrationPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    }
}

/// Ownership-gated the same way as `TutorialCalloutPanelController`, for the same reason.
@MainActor
private final class TutorialCelebrationPanelController {
    static let shared = TutorialCelebrationPanelController()
    private var panel: TutorialCelebrationPanel?
    private var shownForContext: TutorialContext?
    private static let size = NSSize(width: 680, height: 480)

    func show(for context: TutorialContext, centeredOn window: NSWindow) {
        shownForContext = context
        let panel = self.panel ?? TutorialCelebrationPanel()
        self.panel = panel
        panel.contentView = NSHostingView(
            rootView: TutorialCelebrationView().frame(width: Self.size.width, height: Self.size.height)
        )
        panel.setContentSize(Self.size)

        let windowFrame = window.frame
        let origin = NSPoint(
            x: windowFrame.midX - Self.size.width / 2,
            y: windowFrame.midY - Self.size.height / 2
        )
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
    }

    func hideIfShowing(for context: TutorialContext) {
        guard shownForContext == context else { return }
        panel?.orderOut(nil)
        shownForContext = nil
    }

    func hideIfShowing(for contexts: Set<TutorialContext>) {
        guard let shownForContext, contexts.contains(shownForContext) else { return }
        panel?.orderOut(nil)
        self.shownForContext = nil
    }
}

/// Attach to the root of a tour-able surface. Renders nothing unless the active context is in `contexts`.
struct TutorialOverlayHost: ViewModifier {
    let contexts: Set<TutorialContext>

    @ObservedObject private var manager = TutorialManager.shared
    @State private var hostWindow: NSWindow?
    @State private var frames: [String: CGRect] = [:]

    /// Below this, an inline callout has nowhere to go without sitting on top of the very field
    /// it's explaining -- these are the app's own import sheets (~420-460pt wide), not the main
    /// window, which stays comfortably above it.
    private static let smallWindowWidthThreshold: CGFloat = 640

    private var isSmallWindow: Bool {
        (hostWindow?.frame.width ?? .infinity) < Self.smallWindowWidthThreshold
    }

    private var isActive: Bool {
        manager.activeContext.map(contexts.contains) ?? false
    }

    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: TutorialCoordinateSpace.name)
            .background(TutorialWindowAccessor { window in
                hostWindow = window
                syncCalloutPanel()
            })
            .onPreferenceChange(TutorialFramePreferenceKey.self) { frames = $0 }
            .overlay(
                // No `.ignoresSafeArea()` here -- it must match `content`'s own (non-ignoring)
                // frame exactly, since that's the frame `.tutorialAnchor` measured against;
                // ignoring safe area here alone shifted this overlay's origin away from
                // content's, throwing every ring and hole off by the title-bar height.
                GeometryReader { proxy in
                    if let context = manager.activeContext, contexts.contains(context), let step = manager.currentStep {
                        TutorialStepView(
                            step: step,
                            frames: frames,
                            containerSize: proxy.size,
                            showsInlineCallout: !isSmallWindow
                        )
                    }
                }
                .allowsHitTesting(isActive)
            )
            .onChange(of: manager.activeContext) { _, _ in syncCalloutPanel() }
            .onChange(of: manager.stepIndex) { _, _ in syncCalloutPanel() }
            .onChange(of: manager.isCelebrating) { _, isCelebrating in
                guard isActive, let hostWindow, let context = manager.activeContext else { return }
                if isCelebrating {
                    TutorialCelebrationPanelController.shared.show(for: context, centeredOn: hostWindow)
                } else {
                    TutorialCelebrationPanelController.shared.hideIfShowing(for: context)
                }
            }
            // A sheet can close mid-tutorial (the DJ hits its own Close button, say) without
            // `activeContext` ever changing -- left unhandled, the external panel would keep
            // floating there with no window left beside it.
            .onDisappear {
                TutorialCalloutPanelController.shared.hideIfShowing(for: contexts)
                TutorialCelebrationPanelController.shared.hideIfShowing(for: contexts)
            }
    }

    private func syncCalloutPanel() {
        guard isActive, isSmallWindow, let hostWindow, let context = manager.activeContext,
              let step = manager.currentStep
        else {
            TutorialCalloutPanelController.shared.hideIfShowing(for: contexts)
            return
        }
        TutorialCalloutPanelController.shared.show(step, for: context, besideWindow: hostWindow)
    }
}

extension View {
    func tutorialOverlayHost(for contexts: Set<TutorialContext>) -> some View {
        modifier(TutorialOverlayHost(contexts: contexts))
    }
}
