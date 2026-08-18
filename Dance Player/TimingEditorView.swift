//
//  TimingEditorView.swift
//  Dance Player
//
//  Waveform-based start/end trimming with fades, not manual timestamps.
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - Waveform extraction

/// Uniform-duration buckets so a screen column maps to a bucket range by arithmetic, with no index to search at draw time.
struct WaveformData {
    let peaks: [Float]
    let bucketDuration: Double

    var duration: Double { Double(peaks.count) * bucketDuration }

    /// Peak (not average) so zoomed-out waveforms don't flatten; addressed as a fraction of `fileDuration` since decoded length drifts from the asset's reported duration (~52ms on a 5-minute song), which a fixed seconds-per-bucket would let accumulate into drift.
    func peak(from startTime: Double, to endTime: Double, fileDuration: Double) -> Float {
        guard fileDuration > 0, !peaks.isEmpty else { return 0 }

        let bucketsPerSecond = Double(peaks.count) / fileDuration
        let first = Int(startTime * bucketsPerSecond)
        let last = Int(endTime * bucketsPerSecond)
        guard last >= 0, first < peaks.count else { return 0 }

        let lower = max(0, first)
        let upper = min(peaks.count - 1, max(lower, last))

        var result: Float = 0
        for index in lower...upper where peaks[index] > result {
            result = peaks[index]
        }
        return result
    }

    /// Inverse of the above, for reading a position back off the envelope.
    func time(forBucket index: Int, fileDuration: Double) -> Double {
        guard !peaks.isEmpty else { return 0 }
        return Double(index) / Double(peaks.count) * fileDuration
    }
}

enum WaveformExtractionError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "This file doesn't contain an audio track."
        case .readerFailed(let reason):
            return "The audio couldn't be read: \(reason)"
        }
    }
}

enum WaveformExtractor {
    /// Decoded to mono at a reduced rate: downmixing inside the reader is far cheaper than decoding both channels at 44.1k and folding them together here.
    nonisolated private static let sampleRate: Double = 22050
    nonisolated private static let framesPerBucket = 128

    /// ~172 buckets a second, so the closest usable zoom still has several buckets per
    /// screen column rather than a staircase.
    nonisolated static var bucketDuration: Double { Double(framesPerBucket) / sampleRate }

    static func load(url: URL) async throws -> WaveformData {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw WaveformExtractionError.noAudioTrack
        }

        return try await Task.detached(priority: .userInitiated) {
            try extract(asset: asset, audioTrack: audioTrack)
        }.value
    }

    /// Explicitly off the main actor: decoding a five minute file is seconds of solid work,
    /// and inheriting the default isolation would put all of it in front of the booth's UI.
    nonisolated private static func extract(asset: AVAsset, audioTrack: AVAssetTrack) throws -> WaveformData {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw WaveformExtractionError.readerFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw WaveformExtractionError.readerFailed("the decoder refused these settings")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw WaveformExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "unknown reason"
            )
        }

        var peaks: [Float] = []
        var bucketPeak: Float = 0
        var framesInBucket = 0
        var samples = [Int16]()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
                CMSampleBufferInvalidate(sampleBuffer)
                continue
            }

            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = byteCount / MemoryLayout<Int16>.size
            if samples.count < sampleCount {
                samples = [Int16](repeating: 0, count: sampleCount)
            }

            let status = samples.withUnsafeMutableBytes { buffer -> OSStatus in
                guard let base = buffer.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: byteCount,
                    destination: base
                )
            }
            CMSampleBufferInvalidate(sampleBuffer)
            guard status == noErr else { continue }

            for index in 0..<sampleCount {
                // Widened before taking the magnitude: Int16.min has no positive counterpart.
                let magnitude = Float(abs(Int32(samples[index]))) / 32768.0
                if magnitude > bucketPeak { bucketPeak = magnitude }

                framesInBucket += 1
                if framesInBucket == framesPerBucket {
                    peaks.append(bucketPeak)
                    bucketPeak = 0
                    framesInBucket = 0
                }
            }
        }

        if framesInBucket > 0 { peaks.append(bucketPeak) }

        switch reader.status {
        case .completed:
            break
        case .failed, .cancelled:
            throw WaveformExtractionError.readerFailed(
                reader.error?.localizedDescription ?? "reading stopped early"
            )
        default:
            // Reading ran out of samples without being marked complete; a partial envelope
            // still draws correctly for the part of the song it covers.
            break
        }

        guard !peaks.isEmpty else {
            throw WaveformExtractionError.readerFailed("the file decoded to no audio")
        }

        return WaveformData(peaks: peaks, bucketDuration: bucketDuration)
    }
}

/// Cache is bounded by count, not time — a few dozen songs, each envelope well under a megabyte.
final class WaveformCache {
    static let shared = WaveformCache()

    private var storage: [URL: WaveformData] = [:]
    private var order: [URL] = []
    private var inFlight: [URL: Task<WaveformData, Error>] = [:]
    private let limit = 12

    func value(for url: URL) -> WaveformData? { storage[url] }

    /// One decode per file however many callers ask for it — the editor joins the one the
    /// metadata panel already started rather than running a second alongside it.
    func waveform(for url: URL) async throws -> WaveformData {
        if let cached = storage[url] { return cached }
        if let existing = inFlight[url] { return try await existing.value }

        let task = Task { try await WaveformExtractor.load(url: url) }
        inFlight[url] = task

        do {
            let loaded = try await task.value
            inFlight[url] = nil
            store(loaded, for: url)
            return loaded
        } catch {
            // Not cached, so opening the editor will try again and show the reason.
            inFlight[url] = nil
            throw error
        }
    }

    /// Speculative prewarm: decoding takes about a second, so starting it when the panel opens usually finishes before the editor needs it.
    func prewarm(url: URL) {
        guard storage[url] == nil, inFlight[url] == nil else { return }
        Task { _ = try? await waveform(for: url) }
    }

    func store(_ waveform: WaveformData, for url: URL) {
        if storage[url] == nil { order.append(url) }
        storage[url] = waveform

        while order.count > limit {
            let evicted = order.removeFirst()
            storage[evicted] = nil
        }
    }
}

// MARK: - Geometry

/// Maps between the visible slice of the song and pixels. Held as a value so the canvas and
/// the drag handler can't disagree about where a handle is.
private struct WaveformViewport {
    let start: Double
    let visible: Double
    let width: CGFloat

    func x(for time: Double) -> CGFloat {
        guard visible > 0 else { return 0 }
        return CGFloat((time - start) / visible) * width
    }

    func time(for x: CGFloat) -> Double {
        guard width > 0 else { return start }
        return start + Double(x / width) * visible
    }
}

// MARK: - Waveform drawing

private struct WaveformCanvas: View {
    let waveform: WaveformData
    let fileDuration: Double
    let viewStart: Double
    let visibleDuration: Double
    let startTime: Double
    let stopTime: Double
    let fadeIn: Double
    let fadeOut: Double
    let playhead: Double?
    let isPlaying: Bool

    /// Fade handles live in a band along the top, which is what keeps a drag aimed at a fade
    /// from being read as a drag on the trim boundary underneath it.
    static let fadeHandleBandHeight: CGFloat = 26

    private let background = Color(hex: "#0b0b0e")
    private let excludedWave = Color(hex: "#3f3f46")
    private let includedWave = Color(hex: "#3478f6")
    private let boundaryColor = Color(hex: "#eab308")
    private let fadeColor = Color(hex: "#22d3ee")

    var body: some View {
        Canvas { context, size in
            let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: size.width)
            let midY = size.height / 2
            let halfHeight = midY - 6

            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

            drawBars(context: context, size: size, viewport: viewport, midY: midY, halfHeight: halfHeight)
            drawFadeWedges(context: context, size: size, viewport: viewport, midY: midY)
            drawBoundaries(context: context, size: size, viewport: viewport)
            drawFadeHandles(context: context, viewport: viewport)
            drawPlayhead(context: context, size: size, viewport: viewport)
        }
        .drawingGroup()
    }

    private func drawBars(
        context: GraphicsContext,
        size: CGSize,
        viewport: WaveformViewport,
        midY: CGFloat,
        halfHeight: CGFloat
    ) {
        let columnCount = max(1, Int(size.width))
        let secondsPerColumn = visibleDuration / Double(columnCount)

        var included = Path()
        var excluded = Path()

        for column in 0..<columnCount {
            let x = CGFloat(column)
            let columnStart = viewStart + Double(column) * secondsPerColumn
            let columnEnd = columnStart + secondsPerColumn
            guard columnEnd >= 0, columnStart <= waveform.duration else { continue }

            let peak = waveform.peak(from: columnStart, to: columnEnd, fileDuration: fileDuration)
            // A floor of a pixel or so, so silence still reads as a centre line rather than
            // as a gap where the file might have stopped.
            let height = max(1, CGFloat(peak) * halfHeight)
            let bar = CGRect(x: x, y: midY - height, width: 1, height: height * 2)

            let columnMid = columnStart + secondsPerColumn / 2
            if columnMid >= startTime && columnMid <= stopTime {
                included.addRect(bar)
            } else {
                excluded.addRect(bar)
            }
        }

        context.fill(excluded, with: .color(excludedWave))
        context.fill(included, with: .color(includedWave))
    }

    /// The part of the waveform a fade removes, masked back out with the background colour —
    /// what's left is the shape the floor actually hears.
    private func drawFadeWedges(
        context: GraphicsContext,
        size: CGSize,
        viewport: WaveformViewport,
        midY: CGFloat
    ) {
        if fadeIn > 0 {
            let x0 = viewport.x(for: startTime)
            let x1 = viewport.x(for: startTime + fadeIn)
            fill(
                context: context,
                wedge: [CGPoint(x: x0, y: 0), CGPoint(x: x1, y: 0), CGPoint(x: x0, y: midY)],
                mirroredTo: size.height
            )
            var line = Path()
            line.move(to: CGPoint(x: x0, y: midY))
            line.addLine(to: CGPoint(x: x1, y: 0))
            context.stroke(line, with: .color(fadeColor), lineWidth: 1.5)

            var mirrored = Path()
            mirrored.move(to: CGPoint(x: x0, y: midY))
            mirrored.addLine(to: CGPoint(x: x1, y: size.height))
            context.stroke(mirrored, with: .color(fadeColor.opacity(0.5)), lineWidth: 1)
        }

        if fadeOut > 0 {
            let x0 = viewport.x(for: stopTime - fadeOut)
            let x1 = viewport.x(for: stopTime)
            fill(
                context: context,
                wedge: [CGPoint(x: x0, y: 0), CGPoint(x: x1, y: 0), CGPoint(x: x1, y: midY)],
                mirroredTo: size.height
            )
            var line = Path()
            line.move(to: CGPoint(x: x0, y: 0))
            line.addLine(to: CGPoint(x: x1, y: midY))
            context.stroke(line, with: .color(fadeColor), lineWidth: 1.5)

            var mirrored = Path()
            mirrored.move(to: CGPoint(x: x0, y: size.height))
            mirrored.addLine(to: CGPoint(x: x1, y: midY))
            context.stroke(mirrored, with: .color(fadeColor.opacity(0.5)), lineWidth: 1)
        }
    }

    private func fill(context: GraphicsContext, wedge: [CGPoint], mirroredTo height: CGFloat) {
        var path = Path()
        path.move(to: wedge[0])
        for point in wedge.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()

        var mirror = Path()
        mirror.move(to: CGPoint(x: wedge[0].x, y: height - wedge[0].y))
        for point in wedge.dropFirst() {
            mirror.addLine(to: CGPoint(x: point.x, y: height - point.y))
        }
        mirror.closeSubpath()

        context.fill(path, with: .color(background.opacity(0.88)))
        context.fill(mirror, with: .color(background.opacity(0.88)))
    }

    private func drawBoundaries(context: GraphicsContext, size: CGSize, viewport: WaveformViewport) {
        for time in [startTime, stopTime] {
            let x = viewport.x(for: time)
            guard x >= -2, x <= size.width + 2 else { continue }

            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(boundaryColor), lineWidth: 2)

            // A grip at the foot of the line, so it reads as draggable and gives the pointer
            // something to aim at.
            let isStart = time == startTime
            let grip = CGRect(
                x: isStart ? x : x - 9,
                y: size.height - 16,
                width: 9,
                height: 16
            )
            context.fill(Path(grip), with: .color(boundaryColor))
        }
    }

    private func drawFadeHandles(context: GraphicsContext, viewport: WaveformViewport) {
        let handles = [
            viewport.x(for: startTime + fadeIn),
            viewport.x(for: stopTime - fadeOut)
        ]

        for x in handles {
            let dot = CGRect(x: x - 5, y: 3, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot), with: .color(fadeColor))
            context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize, viewport: WaveformViewport) {
        guard let playhead else { return }
        let x = viewport.x(for: playhead)
        guard x >= 0, x <= size.width else { return }

        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(isPlaying ? .white : Color(hex: "#a3a3ac")), lineWidth: 1)
    }
}

// MARK: - Overview strip

/// The whole song at a glance with the zoomed viewport drawn over it — both a map of where
/// you are and the means of moving, which a bare scrollbar wouldn't be.
private struct OverviewStrip: View {
    let waveform: WaveformData
    let fileDuration: Double
    let viewStart: Double
    let visibleDuration: Double
    let startTime: Double
    let stopTime: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let scale = fileDuration > 0 ? width / CGFloat(fileDuration) : 0

            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: "#08080a")))

                let midY = size.height / 2
                let halfHeight = midY - 2
                let columns = max(1, Int(size.width))
                let secondsPerColumn = fileDuration / Double(columns)

                var included = Path()
                var excluded = Path()
                for column in 0..<columns {
                    let columnStart = Double(column) * secondsPerColumn
                    let peak = waveform.peak(
                        from: columnStart,
                        to: columnStart + secondsPerColumn,
                        fileDuration: fileDuration
                    )
                    let barHeight = max(0.5, CGFloat(peak) * halfHeight)
                    let bar = CGRect(x: CGFloat(column), y: midY - barHeight, width: 1, height: barHeight * 2)

                    let mid = columnStart + secondsPerColumn / 2
                    if mid >= startTime && mid <= stopTime {
                        included.addRect(bar)
                    } else {
                        excluded.addRect(bar)
                    }
                }
                context.fill(excluded, with: .color(Color(hex: "#2a2a31")))
                context.fill(included, with: .color(Color(hex: "#2b5fb0")))

                let viewportRect = CGRect(
                    x: CGFloat(viewStart) * scale,
                    y: 0,
                    width: max(3, CGFloat(visibleDuration) * scale),
                    height: size.height
                )
                context.fill(Path(viewportRect), with: .color(Color(hex: "#3478f6").opacity(0.22)))
                context.stroke(
                    Path(viewportRect.insetBy(dx: 0.5, dy: 0.5)),
                    with: .color(Color(hex: "#3478f6")),
                    lineWidth: 1
                )
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard scale > 0 else { return }
                        // The grab centres the viewport, so a click anywhere jumps there.
                        onScrub(Double(value.location.x / scale) - visibleDuration / 2)
                    }
            )
        }
    }
}

// MARK: - Time ruler

private struct TimeRuler: View {
    let viewStart: Double
    let visibleDuration: Double

    /// Steps chosen so labels stay legible at every zoom without ever colliding.
    private static let candidateSteps: [Double] = [
        0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300
    ]

    var body: some View {
        Canvas { context, size in
            let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: size.width)
            let targetLabelCount = max(2.0, Double(size.width) / 90.0)
            let rawStep = visibleDuration / targetLabelCount
            let step = Self.candidateSteps.first { $0 >= rawStep } ?? Self.candidateSteps.last!

            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(hex: "#0b0b0e"))
            )

            var tick = (viewStart / step).rounded(.down) * step
            while tick <= viewStart + visibleDuration {
                defer { tick += step }
                guard tick >= 0 else { continue }

                let x = viewport.x(for: tick)
                var line = Path()
                line.move(to: CGPoint(x: x, y: size.height - 5))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(Color(hex: "#3f3f46")), lineWidth: 1)

                let text = Text(TimingFormat.label(tick, step: step))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#71717a"))
                context.draw(text, at: CGPoint(x: x + 3, y: size.height - 12), anchor: .leading)
            }
        }
    }
}

// MARK: - Formatting

enum TimingFormat {
    /// `m:ss.d`, which is fine enough to place a downbeat and short enough to sit in a
    /// narrow field.
    static func precise(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let remainder = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, remainder)
    }

    /// Drops the decimal once the ruler's step is a second or more, where it's just noise.
    static func label(_ seconds: Double, step: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return step >= 1
            ? String(format: "%d:%02d", minutes, Int(remainder.rounded()))
            : String(format: "%d:%04.1f", minutes, remainder)
    }

    /// Accepts what `precise` writes, plus a bare number of seconds — typing "12" for twelve
    /// seconds in is the obvious thing to try.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1:
            return Double(parts[0])
        case 2:
            guard let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }
}

// MARK: - Window plumbing

/// Reaches the `NSWindow` behind a SwiftUI hierarchy, so a key monitor can tell events aimed
/// at this window from events aimed at the booth.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Editor

struct TimingEditorView: View {
    @ObservedObject var player: PlayerController
    let trackID: UUID

    @State private var waveform: WaveformData?
    @State private var loadErrorMessage: String?

    // The draft. Nothing here reaches the queue until it's applied.
    @State private var draftStart: Double = 0
    @State private var draftEnd: Double = 0
    @State private var draftFadeIn: Double = 0
    @State private var draftFadeOut: Double = 0

    /// Undo inside the editor works on the draft, one entry per gesture rather than per frame
    /// of a drag. Applying is what puts a single step on the app's own undo stack.
    private struct DraftTiming: Equatable {
        var start: Double
        var end: Double
        var fadeIn: Double
        var fadeOut: Double
    }

    @State private var draftUndoStack: [DraftTiming] = []
    @State private var draftRedoStack: [DraftTiming] = []

    /// The only remaining record of where the song started out, since edits commit as they're made — what Reset and the app's undo restore.
    @State private var openingDraft: DraftTiming?
    @State private var hasRecordedSessionUndo = false
    @State private var hasHydrated = false

    @State private var startText: String = ""
    @State private var endText: String = ""

    @State private var viewStart: Double = 0
    @State private var visibleDuration: Double = 1

    @State private var dragMode: DragMode?
    @State private var dragAnchor: Double = 0
    /// Which notch a drag last ticked at, so feedback fires once per notch crossed rather than
    /// on every frame of the gesture.
    @State private var lastHapticNotch: Int?
    /// Where the playhead sits when this song isn't the one the app is cued to. Once it is,
    /// the position comes from the player itself.
    @State private var localPlayhead: Double = 0
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// Needed by the scroll handler to turn a scroll distance into a span of time.
    @State private var waveformWidth: CGFloat = 0

    private enum DragMode {
        case start
        case end
        case fadeIn
        case fadeOut
        case pan
    }

    /// Closer than this and the waveform is showing individual cycles, which helps nobody.
    private static let minimumVisibleDuration: Double = 0.4
    private static let maximumFade: Double = 20

    private var track: Track? {
        player.tracks.first(where: { $0.id == trackID })
    }

    /// The song as it would be if the draft were applied — handed to the mix builder so a
    /// preview is literally the same code path as playback.
    private var draftTrack: Track? {
        guard var track else { return nil }
        track.startTime = draftStart
        track.endTime = draftEnd < track.duration ? draftEnd : nil
        track.fadeInDuration = draftFadeIn
        track.fadeOutDuration = draftFadeOut
        return track
    }

    private var stopTime: Double {
        draftTrack?.playbackStopTime ?? draftEnd
    }

    // MARK: Playback
    // The editor drives the app's own player, so auditioning an edit is playback in every sense and survives the sheet closing and reopening.

    private var isLiveTrack: Bool {
        player.currentTrack?.id == trackID
    }

    private var isPlayingThisTrack: Bool {
        isLiveTrack && player.isPlaying
    }

    /// The engine counts from the trim point and in played seconds; the waveform is drawn in
    /// the file's own seconds from zero, so the reading has to be converted back.
    private var playheadTime: Double {
        guard isLiveTrack, let live = player.currentTrack else { return localPlayhead }
        return live.startTime + player.currentTime / live.speedMultiplier
    }

    /// What the booth's transport shows for the same instant: time since the start point,
    /// scaled by the tempo, which is the song's played length rather than its file position.
    private var playedTime: Double {
        guard let track else { return 0 }
        return max(0, (playheadTime - track.startTime) * track.speedMultiplier)
    }

    /// A skipped song can't be cued: the transport would step over it to its neighbour, and
    /// the DJ would be listening to a different song than the one on screen.
    private var canPlay: Bool {
        player.tracks.first(where: { $0.id == trackID })?.isSkipped == false
    }

    private var hasUnsavedChanges: Bool {
        guard let track else { return false }
        return abs(track.startTime - draftStart) > 0.001
            || abs(track.resolvedEndTime - draftEnd) > 0.001
            || abs(track.fadeInDuration - draftFadeIn) > 0.001
            || abs(track.fadeOutDuration - draftFadeOut) > 0.001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))

            waveformSection
                .padding(.horizontal, 16)
                .padding(.top, 14)

            zoomControls
                .padding(.horizontal, 16)
                .padding(.top, 10)

            Divider().background(Color(hex: "#242429")).padding(.top, 14)

            VStack(alignment: .leading, spacing: 16) {
                boundaryControls
                fadeControls
            }
            .padding(16)

            Spacer(minLength: 0)

            Divider().background(Color(hex: "#242429"))
            footer
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 660, idealHeight: 760)
        .background(Color(hex: "#0e0e10"))
        .foregroundColor(.white)
        .background(WindowAccessor { hostWindow = $0 })
        .onAppear {
            hydrate()
            loadWaveform()
            installKeyMonitor()
            installScrollMonitor()
        }
        .onDisappear {
            removeMonitors()
            // Edits commit as they're made, so this is only a backstop for anything the last
            // gesture left behind — then the debounced library write is settled up.
            apply()
            player.flushPendingTrackSave()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Song")
                    .font(.system(size: 15, weight: .bold))
                Text(track?.artist ?? "")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(regionSummary)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(hex: "#3478f6"))
                if let track, track.tempoPercentage != 0 {
                    Text(String(
                        format: "plays as %@ at %+.1f%%",
                        TimingFormat.precise(regionLength / track.speedMultiplier),
                        track.tempoPercentage
                    ))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#71717a"))
                }
            }
        }
        .padding(16)
    }

    private var regionLength: Double {
        max(0, draftEnd - draftStart)
    }

    private var regionSummary: String {
        "\(TimingFormat.precise(draftStart)) → \(TimingFormat.precise(draftEnd))  (\(TimingFormat.precise(regionLength)))"
    }

    // MARK: Waveform

    @ViewBuilder
    private var waveformSection: some View {
        VStack(spacing: 0) {
            if let waveform {
                GeometryReader { geometry in
                    WaveformCanvas(
                        waveform: waveform,
                        fileDuration: track?.duration ?? waveform.duration,
                        viewStart: viewStart,
                        visibleDuration: visibleDuration,
                        startTime: draftStart,
                        stopTime: stopTime,
                        fadeIn: draftTrack?.effectiveFadeInDuration ?? 0,
                        fadeOut: draftTrack?.effectiveFadeOutDuration ?? 0,
                        playhead: playheadTime,
                        isPlaying: isPlayingThisTrack
                    )
                    .contentShape(Rectangle())
                    .onAppear { waveformWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in waveformWidth = width }
                    .gesture(dragGesture(width: geometry.size.width))
                    .gesture(MagnificationGesture().onChanged { scale in
                        // Pinch reads as a ratio against the gesture's start; anchoring on the
                        // centre keeps whatever is being examined in view.
                        zoom(toVisible: visibleDuration / scale, anchorTime: viewStart + visibleDuration / 2)
                    })
                }
                .frame(height: 210)

                TimeRuler(viewStart: viewStart, visibleDuration: visibleDuration)
                    .frame(height: 18)

                Divider().background(Color(hex: "#242429"))

                OverviewStrip(
                    waveform: waveform,
                    fileDuration: track?.duration ?? waveform.duration,
                    viewStart: viewStart,
                    visibleDuration: visibleDuration,
                    startTime: draftStart,
                    stopTime: stopTime,
                    onScrub: { setViewStart($0) }
                )
                .frame(height: 40)
            } else if let loadErrorMessage {
                placeholder(
                    icon: "exclamationmark.triangle",
                    text: loadErrorMessage,
                    tint: Color(hex: "#f97316")
                )
            } else {
                placeholder(icon: "waveform", text: "Reading the audio…", tint: Color(hex: "#71717a"))
            }
        }
        .background(Color(hex: "#0b0b0e"))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "#242429"), lineWidth: 1)
        )
    }

    private func placeholder(icon: String, text: String, tint: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 26))
            Text(text)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
        }
        .foregroundColor(tint)
        .frame(maxWidth: .infinity)
        .frame(height: 208)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: width)

                if dragMode == nil {
                    dragMode = hitTest(at: value.startLocation, viewport: viewport)
                    dragAnchor = viewport.time(for: value.startLocation.x)
                    // Panning moves the view, not the song, so it isn't an edit.
                    if dragMode != .pan { recordDraftUndo() }
                }

                let time = viewport.time(for: value.location.x)

                switch dragMode {
                case .start:
                    setStart(time)
                    tickHaptics(draftStart, every: 1)
                case .end:
                    setEnd(time)
                    tickHaptics(draftEnd, every: 1)
                case .fadeIn:
                    draftFadeIn = clampFade(time - draftStart)
                    // A quarter second, not a whole one: a fade is usually only a few seconds
                    // long, so ticking per second would give one or two over the whole drag.
                    tickHaptics(draftFadeIn, every: 0.25)
                case .fadeOut:
                    draftFadeOut = clampFade(stopTime - time)
                    tickHaptics(draftFadeOut, every: 0.25)
                case .pan:
                    // The grabbed instant stays under the pointer, which is what makes a drag
                    // feel like moving the paper rather than moving a scrollbar.
                    setViewStart(dragAnchor - Double(value.location.x / width) * visibleDuration)
                case .none:
                    break
                }
            }
            .onEnded { value in
                let isClick = abs(value.translation.width) < 3 && abs(value.translation.height) < 3
                if isClick, dragMode == .pan {
                    let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: width)
                    movePlayhead(to: viewport.time(for: value.location.x))
                }
                if dragMode != .pan {
                    dropRedundantDraftUndo()
                    // Committed on release rather than through the drag: one edit, one write.
                    apply()
                    HapticFeedback.perform(.generic)
                }
                dragMode = nil
                lastHapticNotch = nil
            }
    }

    /// One tick per notch crossed, which gives a drag a sense of scale — and at close zoom, of
    /// how far it has actually moved.
    private func tickHaptics(_ value: Double, every increment: Double) {
        guard increment > 0 else { return }
        let notch = Int((value / increment).rounded(.down))
        guard notch != lastHapticNotch else { return }
        lastHapticNotch = notch
        HapticFeedback.perform(.alignment)
    }

    private func hitTest(at point: CGPoint, viewport: WaveformViewport) -> DragMode {
        let grabRadius: CGFloat = 9

        if point.y <= WaveformCanvas.fadeHandleBandHeight {
            let fadeInX = viewport.x(for: draftStart + (draftTrack?.effectiveFadeInDuration ?? 0))
            let fadeOutX = viewport.x(for: stopTime - (draftTrack?.effectiveFadeOutDuration ?? 0))
            if abs(point.x - fadeInX) <= grabRadius { return .fadeIn }
            if abs(point.x - fadeOutX) <= grabRadius { return .fadeOut }
        }

        let startX = viewport.x(for: draftStart)
        let endX = viewport.x(for: draftEnd)
        // Ties go to whichever boundary is nearer, so the two can be dragged apart even when
        // zoomed out far enough that they overlap.
        if abs(point.x - startX) <= grabRadius || abs(point.x - endX) <= grabRadius {
            return abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
        }

        return .pan
    }

    // MARK: Zoom

    private var zoomControls: some View {
        HStack(spacing: 10) {
            Button { zoomStep(factor: 1 / 1.6) } label: { Image(systemName: "plus.magnifyingglass") }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .help("Zoom in (⌘+)")

            Slider(
                value: Binding(
                    get: { zoomFraction },
                    set: { setZoomFraction($0) }
                ),
                in: 0...1
            )
            .frame(maxWidth: 260)

            Button { zoomStep(factor: 1.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .help("Zoom out (⌘−)")

            Divider().frame(height: 18)

            Button("Whole Song") { fitAll() }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .help("Fit the whole song in view (⌘0)")
            Button("Zoom to Start") { focus(on: draftStart) }
                .buttonStyle(.bordered)
                .pointingHandCursor()
            Button("Zoom to End") { focus(on: draftEnd) }
                .buttonStyle(.bordered)
                .pointingHandCursor()

            Spacer()

            Text(String(format: "%@ visible", TimingFormat.precise(visibleDuration)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "#71717a"))
        }
        .font(.system(size: 11))
    }

    /// 0 shows the whole song, 1 the closest zoom. Logarithmic, because a linear slider
    /// spends nearly all its travel in the wide end where nothing changes.
    private var zoomFraction: Double {
        guard let fileDuration = track?.duration, fileDuration > Self.minimumVisibleDuration else { return 0 }
        let ratio = Self.minimumVisibleDuration / fileDuration
        return log(visibleDuration / fileDuration) / log(ratio)
    }

    private func setZoomFraction(_ fraction: Double) {
        guard let fileDuration = track?.duration, fileDuration > Self.minimumVisibleDuration else { return }
        let ratio = Self.minimumVisibleDuration / fileDuration
        let target = fileDuration * pow(ratio, max(0, min(1, fraction)))
        zoom(toVisible: target, anchorTime: viewStart + visibleDuration / 2)
    }

    private func zoomStep(factor: Double) {
        // Anchored on the playhead when it's on screen: after auditioning a fade, that's the
        // spot being worked on.
        let playhead = playheadTime
        let anchor = (playhead >= viewStart && playhead <= viewStart + visibleDuration)
            ? playhead
            : viewStart + visibleDuration / 2
        zoom(toVisible: visibleDuration * factor, anchorTime: anchor)
    }

    private func zoom(toVisible target: Double, anchorTime: Double) {
        guard let fileDuration = track?.duration, fileDuration > 0 else { return }

        let clamped = max(Self.minimumVisibleDuration, min(target, fileDuration))
        let anchorFraction = visibleDuration > 0 ? (anchorTime - viewStart) / visibleDuration : 0.5
        visibleDuration = clamped
        setViewStart(anchorTime - anchorFraction * clamped)
    }

    private func fitAll() {
        guard let fileDuration = track?.duration, fileDuration > 0 else { return }
        visibleDuration = fileDuration
        viewStart = 0
    }

    private func focus(on time: Double) {
        zoom(toVisible: min(8, track?.duration ?? 8), anchorTime: time)
        setViewStart(time - visibleDuration / 2)
    }

    private func setViewStart(_ proposed: Double) {
        guard let fileDuration = track?.duration else { return }
        viewStart = max(0, min(proposed, max(0, fileDuration - visibleDuration)))
    }

    // MARK: Boundary and fade controls

    private var boundaryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("TRIM")

            boundaryRow(
                title: "Start",
                text: $startText,
                commit: { edit { setStart(TimingFormat.parse(startText) ?? draftStart) } },
                nudge: { amount in edit { setStart(draftStart + amount) } },
                setToPlayhead: { edit { setStart(playheadTime) } }
            )

            boundaryRow(
                title: "End",
                text: $endText,
                commit: { edit { setEnd(TimingFormat.parse(endText) ?? draftEnd) } },
                nudge: { amount in edit { setEnd(draftEnd + amount) } },
                setToPlayhead: { edit { setEnd(playheadTime) } }
            )

            HStack(spacing: 8) {
                Button("Use Whole File") {
                    edit {
                        setStart(0)
                        setEnd(contentEndTime)
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()

                Text(wholeFileCaption)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#71717a"))
            }
            .font(.system(size: 11))
        }
    }

    private func boundaryRow(
        title: String,
        text: Binding<String>,
        commit: @escaping () -> Void,
        nudge: @escaping (Double) -> Void,
        setToPlayhead: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.gray)
                .frame(width: 42, alignment: .leading)

            TextField("0:00.0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 90)
                .onSubmit(commit)

            Button("−1s") { nudge(-1) }.buttonStyle(.bordered)
            .pointingHandCursor()
            Button("−0.1s") { nudge(-0.1) }.buttonStyle(.bordered)
            .pointingHandCursor()
            Button("+0.1s") { nudge(0.1) }.buttonStyle(.bordered)
            .pointingHandCursor()
            Button("+1s") { nudge(1) }.buttonStyle(.bordered)
            .pointingHandCursor()

            Button("Set to Playhead", action: setToPlayhead)
                .buttonStyle(.bordered)
                .pointingHandCursor()

            Spacer()
        }
        .font(.system(size: 11))
    }

    private var fadeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("FADES")

            fadeRow(
                title: "Fade in",
                value: $draftFadeIn,
                audition: { auditionIntro() },
                auditionLabel: "Preview Intro"
            )

            fadeRow(
                title: "Fade out",
                value: $draftFadeOut,
                audition: { auditionOutro() },
                auditionLabel: "Preview Outro"
            )

            if let draftTrack,
               draftTrack.effectiveFadeInDuration + draftTrack.effectiveFadeOutDuration
                    < draftFadeIn + draftFadeOut - 0.01 {
                Text("The two fades are longer than the trimmed song, so they've been scaled to fit it.")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#f97316"))
            }

            Text("Fades are measured in the song's own seconds, so they keep their musical length when the tempo is changed.")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#71717a"))
        }
    }

    private func fadeRow(
        title: String,
        value: Binding<Double>,
        audition: @escaping () -> Void,
        auditionLabel: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.gray)
                .frame(width: 62, alignment: .leading)

            Slider(
                value: Binding(
                    get: { value.wrappedValue },
                    set: { updated in
                        // Ticked from the binding since a Slider only reports the grab and release, not what's in between.
                        tickHaptics(updated, every: 0.25)
                        value.wrappedValue = updated
                    }
                ),
                in: 0...Self.maximumFade,
                onEditingChanged: { isEditing in
                    // One entry per drag of the slider, taken as it's grabbed.
                    if isEditing {
                        recordDraftUndo()
                        lastHapticNotch = nil
                    } else {
                        lastHapticNotch = nil
                        dropRedundantDraftUndo()
                        apply()
                        HapticFeedback.perform(.levelChange)
                    }
                }
            )
            .frame(maxWidth: 240)

            Text(String(format: "%.1fs", value.wrappedValue))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(value.wrappedValue > 0 ? Color(hex: "#22d3ee") : .gray)
                .frame(width: 44, alignment: .leading)

            Button("None") { edit { value.wrappedValue = 0 } }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(value.wrappedValue == 0)

            Button(auditionLabel, action: audition)
                .buttonStyle(.bordered)
                .pointingHandCursor()

            Spacer()
        }
        .font(.system(size: 11))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(Color(hex: "#71717a"))
            .tracking(0.6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                togglePlayback()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isPlayingThisTrack ? "pause.fill" : "play.fill")
                    Text(isPlayingThisTrack ? "Pause" : "Play from Playhead")
                }
                .frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
            .disabled(!canPlay)
            .help(canPlay ? "Space" : "This song is skipped, so it can't be cued up")

            // Both readings, since they're different clocks — file time vs. played time from the start point — and the difference is the whole trim.
            VStack(alignment: .leading, spacing: 1) {
                Text("\(TimingFormat.precise(playheadTime)) in file")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                Text("\(TimingFormat.precise(playedTime)) played")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(hex: "#71717a"))
            }

            Spacer()

            Button("Reset") { resetToOpeningState() }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(!hasSessionChanges)
                .help("Put the start, end and fades back to what they were when this opened")

            Button("Done") {
                apply()
                player.closeTimingEditor()
            }
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(16)
    }

    // MARK: Editing

    private func setStart(_ proposed: Double) {
        // Never past the end: a start after the end is a song that can't play at all.
        draftStart = max(0, min(proposed, draftEnd - 0.25))
        startText = TimingFormat.precise(draftStart)
    }

    private func setEnd(_ proposed: Double) {
        guard let track else { return }
        draftEnd = min(track.duration, max(proposed, draftStart + 0.25))
        endText = TimingFormat.precise(draftEnd)
    }

    /// Where the audio actually stops, ignoring a silent tail — the same -70 dB boundary the importer's trailing-silence scan uses, read off the envelope already in memory.
    private var contentEndTime: Double {
        let fileDuration = track?.duration ?? 0
        guard let waveform else { return fileDuration }

        let silenceThreshold: Float = 0.000316
        guard let lastAudible = waveform.peaks.lastIndex(where: { $0 > silenceThreshold }) else {
            return fileDuration
        }

        let boundary = waveform.time(forBucket: lastAudible + 1, fileDuration: fileDuration)
        // Under half a second of tail isn't worth cutting, which is the bar the importer sets.
        return fileDuration - boundary > 0.5 ? boundary : fileDuration
    }

    private var wholeFileCaption: String {
        let fileDuration = track?.duration ?? 0
        let trimmed = fileDuration - contentEndTime
        return trimmed > 0.5
            ? String(format: "The whole song, less %.1fs of silence at the end.", trimmed)
            : "The whole song."
    }

    private func clampFade(_ proposed: Double) -> Double {
        max(0, min(proposed, Self.maximumFade))
    }

    /// One entry on the undo stack, then straight into the track — there's no Apply button.
    private func edit(_ change: () -> Void) {
        recordDraftUndo()
        change()
        dropRedundantDraftUndo()
        apply()
        HapticFeedback.perform(.levelChange)
    }

    // MARK: Draft undo

    private var currentDraft: DraftTiming {
        DraftTiming(start: draftStart, end: draftEnd, fadeIn: draftFadeIn, fadeOut: draftFadeOut)
    }

    /// Called before a gesture or a button changes anything — at the start of a drag, not
    /// through it, so one drag of a handle is one undo.
    private func recordDraftUndo() {
        draftUndoStack.append(currentDraft)
        if draftUndoStack.count > 50 { draftUndoStack.removeFirst() }
        draftRedoStack.removeAll()
    }

    /// A click that turned out not to move anything shouldn't cost an undo press to get past.
    private func dropRedundantDraftUndo() {
        if draftUndoStack.last == currentDraft { draftUndoStack.removeLast() }
    }

    /// Whether anything has moved since the editor opened, which is what Reset undoes.
    private var hasSessionChanges: Bool {
        guard let openingDraft else { return false }
        return openingDraft != currentDraft
    }

    private func resetToOpeningState() {
        guard let openingDraft, openingDraft != currentDraft else { return }
        recordDraftUndo()
        restoreDraft(openingDraft)
    }

    private func undoDraft() {
        guard let previous = draftUndoStack.popLast() else { return }
        draftRedoStack.append(currentDraft)
        restoreDraft(previous)
    }

    private func redoDraft() {
        guard let next = draftRedoStack.popLast() else { return }
        draftUndoStack.append(currentDraft)
        restoreDraft(next)
    }

    private func restoreDraft(_ draft: DraftTiming) {
        draftStart = draft.start
        draftEnd = draft.end
        draftFadeIn = draft.fadeIn
        draftFadeOut = draft.fadeOut
        startText = TimingFormat.precise(draftStart)
        endText = TimingFormat.precise(draftEnd)
        HapticFeedback.perform(.levelChange)
        apply()
    }

    private func hydrate(force: Bool = false) {
        guard let track, !hasHydrated || force else { return }

        draftStart = track.startTime
        draftEnd = track.resolvedEndTime
        draftFadeIn = track.fadeInDuration
        draftFadeOut = track.fadeOutDuration
        startText = TimingFormat.precise(draftStart)
        endText = TimingFormat.precise(draftEnd)

        if !hasHydrated {
            visibleDuration = max(Self.minimumVisibleDuration, track.duration)
            viewStart = 0
            localPlayhead = track.startTime
            openingDraft = currentDraft
            hasHydrated = true
        }
    }

    private func apply() {
        // Guarded so that pressing play repeatedly doesn't stack identical entries on the
        // app's undo, and so closing an untouched editor is not itself an edit.
        guard hasUnsavedChanges,
              let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        // Once per editor session, not once per nudge: from outside, opening the editor and
        // working on a song is a single thing that was done, and a single thing to undo.
        if !hasRecordedSessionUndo {
            player.recordUndoSnapshot("Edit Timing")
            hasRecordedSessionUndo = true
        }

        let previousStart = player.tracks[index].startTime

        var updated = player.tracks[index]
        updated.startTime = draftStart
        // Matching the metadata editor: an end on the file's own end is stored as "no end",
        // so a re-import that changes the duration isn't left trimmed to the old one.
        updated.endTime = draftEnd < updated.duration ? draftEnd : nil
        updated.fadeInDuration = draftFadeIn
        updated.fadeOutDuration = draftFadeOut
        player.tracks[index] = updated

        // The metadata panel holds its own copy and re-saves it on close, which would put the
        // old timestamps straight back.
        if player.selectedTrackForEditing?.id == trackID {
            player.selectedTrackForEditing = updated
        }

        if player.currentIndex == index {
            player.synchronizeActiveTrackSettings()
            player.recueForTrimChange(previousStartTime: previousStart)
        }

        // Debounced: this now runs on every handle release and every slider, and a library
        // write is not cheap. Flushed when the editor closes.
        player.saveTrackSoon(updated)
        HapticFeedback.perform(.levelChange)
    }

    private func loadWaveform() {
        guard let track else { return }

        if let cached = WaveformCache.shared.value(for: track.url) {
            waveform = cached
            return
        }

        let url = track.url
        Task {
            do {
                waveform = try await WaveformCache.shared.waveform(for: url)
            } catch {
                loadErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Transport

    private func togglePlayback() {
        if isPlayingThisTrack {
            player.togglePlayPause()
        } else {
            startPlayback(from: playheadTime)
        }
    }

    private func auditionIntro() {
        startPlayback(from: draftStart)
    }

    private func auditionOutro() {
        let leadIn = max(6, draftFadeOut + 3)
        startPlayback(from: max(draftStart, stopTime - leadIn))
    }

    /// Committing first is what makes the audition honest: the engine reads the stored trim
    /// and fades, so an unapplied draft would be heard as whatever was there before.
    private func startPlayback(from absolute: Double) {
        apply()

        guard canPlay, let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = player.tracks[index]
        let relative = max(0, (absolute - track.startTime) * track.speedMultiplier)

        // Checks loaded audio, not just index, since the item may hold a stale file; cues without autoplay so the song can be repositioned before an outro audition starts with a burst of the intro.
        if !player.hasLoadedAudio(forTrackID: trackID) || player.isBetweenSongs {
            player.prepareTrack(index: index, autoPlay: false)
        }

        player.seek(to: relative)
        player.resumeLoadedTrack()
        localPlayhead = absolute

        player.reportPlaybackPosition(
            requested: absolute,
            label: "timing editor audition"
        )
    }

    private func movePlayhead(to absolute: Double) {
        let bounded = max(draftStart, min(absolute, stopTime))
        localPlayhead = bounded

        guard isLiveTrack, let live = player.currentTrack else { return }
        player.seek(to: max(0, (bounded - live.startTime) * live.speedMultiplier))
    }

    // MARK: Keyboard

    /// Scrolling the waveform along in time. Nothing else in the sheet scrolls, so the wheel
    /// is free to mean this and only this — no hit-testing the pointer against the canvas.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let hostWindow, event.window === hostWindow else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // A trackpad reports horizontal scrolls in deltaX; a wheel mouse has only deltaY,
            // so it falls back to that rather than doing nothing at all.
            let horizontal = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard horizontal != 0 else { return nil }

            // Pixel-precise devices report points; a notched wheel reports lines.
            let points = event.hasPreciseScrollingDeltas ? horizontal : horizontal * 16

            if modifiers.contains(.command) || modifiers.contains(.option) {
                zoom(toVisible: visibleDuration * (1 - Double(points) / 300),
                     anchorTime: viewStart + visibleDuration / 2)
                return nil
            }

            guard waveformWidth > 0 else { return nil }
            setViewStart(viewStart - Double(points / waveformWidth) * visibleDuration)
            return nil
        }
    }

    /// SwiftUI's own shortcuts are unreliable in a sheet the app presents itself, and the
    /// zoom keys have to beat the booth's spacebar handler to the event either way.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let hostWindow, event.window === hostWindow else { return event }
            if hostWindow.firstResponder is NSTextView { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""

            if modifiers == .command {
                switch characters {
                case "+", "=":
                    zoomStep(factor: 1 / 1.6)
                    return nil
                case "-", "_":
                    zoomStep(factor: 1.6)
                    return nil
                case "0":
                    fitAll()
                    return nil
                case "z":
                    undoDraft()
                    return nil
                case "y":
                    redoDraft()
                    return nil
                default:
                    return event
                }
            }

            if modifiers.isEmpty, event.keyCode == 49 { // spacebar
                togglePlayback()
                return nil
            }

            return event
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        keyMonitor = nil
        scrollMonitor = nil
    }
}
