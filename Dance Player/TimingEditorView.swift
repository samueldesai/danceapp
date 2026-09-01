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

    /// Peak (not average) so zoomed-out waveforms don't flatten; addressed as a fraction of `fileDuration` to avoid drift from a fixed seconds-per-bucket.
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
    /// Decoded to mono at a reduced rate, since downmixing in the reader is cheaper than decoding both channels and folding them here.
    nonisolated private static let sampleRate: Double = 22050
    nonisolated private static let framesPerBucket = 128

    /// ~172 buckets a second, so the closest zoom still shows several buckets per screen column rather than a staircase.
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

    /// Explicitly off the main actor, since decoding a five-minute file would otherwise block the booth's UI.
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
            // A partial envelope (samples ran out before completion) still draws correctly for the part it covers.
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

    /// One decode per file no matter how many callers ask — the editor joins a decode the metadata panel already started.
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

    /// Keyed purely by path, so a file overwritten in place (e.g. a re-download) doesn't keep showing the old envelope.
    func invalidate(url: URL) {
        storage[url] = nil
        inFlight[url]?.cancel()
        inFlight[url] = nil
        order.removeAll { $0 == url }
    }
}

// MARK: - Geometry

/// Maps between the visible slice of the song and pixels; a value type so the canvas and drag handler can't disagree.
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
    /// The mouse's current position, shown as a preview line so a blade lands exactly where it looks like it will.
    let hoverTime: Double?

    /// Fade handles live in a band along the top, keeping a fade drag from being read as a trim-boundary drag.
    static let fadeHandleBandHeight: CGFloat = 26

    private let background = Color(hex: "#0b0b0e")
    private let excludedWave = Color(hex: "#3f3f46")
    private let includedWave = Color(hex: "#3478f6")
    private let boundaryColor = Color(hex: "#eab308")
    private let fadeColor = Color(hex: "#22d3ee")
    private let hoverColor = Color.white

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
            drawHoverLine(context: context, size: size, viewport: viewport)
        }
        .drawingGroup()
    }

    private func drawHoverLine(context: GraphicsContext, size: CGSize, viewport: WaveformViewport) {
        guard let hoverTime else { return }
        let x = viewport.x(for: hoverTime)
        guard x >= 0, x <= size.width else { return }

        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(hoverColor.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
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
            // A floor of a pixel or so, so silence reads as a centre line rather than a gap where playback stopped.
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

    /// The part of the waveform a fade removes, masked out with the background colour — what's left is what plays.
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

            // A grip at the foot of the line so it reads as draggable and gives the pointer something to aim at.
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

// MARK: - Arranged (multi-lane) waveform drawing

/// Draws each clip as real waveform content remapped from its source position to its timeline position, not an abstract block diagram.
private struct ArrangedWaveformCanvas: View {
    let waveform: WaveformData
    let fileDuration: Double
    let viewStart: Double
    let visibleDuration: Double
    let clips: [TrackClip]
    let selectedClipID: UUID?
    let playhead: Double?
    let isPlaying: Bool
    let laneCount: Int
    let hoverTime: Double?

    private let background = Color(hex: "#0b0b0e")
    private let laneBackground = Color(hex: "#141417")
    private let waveColor = Color(hex: "#3478f6")
    private let selectedWaveColor = Color(hex: "#eab308")
    private let fadeColor = Color(hex: "#22d3ee")
    private let clipBorder = Color(hex: "#3a3a44")

    var body: some View {
        Canvas { context, size in
            let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: size.width)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

            let laneHeight = size.height / CGFloat(laneCount)
            for lane in 0..<laneCount {
                let rect = CGRect(x: 0, y: CGFloat(lane) * laneHeight, width: size.width, height: laneHeight)
                context.fill(Path(rect), with: .color(laneBackground))
            }
            for lane in 1..<laneCount {
                let y = CGFloat(lane) * laneHeight
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(Color(hex: "#242429")), lineWidth: 1)
            }

            for clip in clips {
                drawClip(clip, context: context, viewport: viewport, laneHeight: laneHeight, size: size)
            }

            drawPlayhead(context: context, size: size, viewport: viewport)
            drawHoverLine(context: context, size: size, viewport: viewport)
        }
        .drawingGroup()
    }

    private func drawHoverLine(context: GraphicsContext, size: CGSize, viewport: WaveformViewport) {
        guard let hoverTime else { return }
        let x = viewport.x(for: hoverTime)
        guard x >= 0, x <= size.width else { return }

        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawClip(
        _ clip: TrackClip,
        context: GraphicsContext,
        viewport: WaveformViewport,
        laneHeight: CGFloat,
        size: CGSize
    ) {
        let laneTop = CGFloat(clip.lane) * laneHeight
        let midY = laneTop + laneHeight / 2
        let halfHeight = laneHeight / 2 - 6

        let x0 = viewport.x(for: clip.timelineStart)
        let x1 = viewport.x(for: clip.timelineEnd)
        guard x1 >= 0, x0 <= size.width, x1 > x0 else { return }

        let isSelected = clip.id == selectedClipID
        let clipRect = CGRect(x: max(0, x0), y: laneTop + 2, width: min(size.width, x1) - max(0, x0), height: laneHeight - 4)

        if isSelected {
            context.fill(Path(roundedRect: clipRect, cornerSize: CGSize(width: 4, height: 4)), with: .color(.white.opacity(0.08)))
        }

        let columnStart = max(0, Int(x0))
        let columnEnd = min(Int(size.width), Int(x1))
        if columnEnd > columnStart {
            let secondsPerColumn = visibleDuration / Double(size.width)
            var bars = Path()
            for column in columnStart..<columnEnd {
                let timelineColumnStart = viewport.time(for: CGFloat(column))
                let timelineColumnEnd = timelineColumnStart + secondsPerColumn
                // This column's audio comes from the clip's source-file position, not its drawn timeline position.
                let sourceColumnStart = clip.sourceStart + (timelineColumnStart - clip.timelineStart)
                let sourceColumnEnd = clip.sourceStart + (timelineColumnEnd - clip.timelineStart)
                let peak = waveform.peak(from: sourceColumnStart, to: sourceColumnEnd, fileDuration: fileDuration)
                let height = max(1, CGFloat(peak) * halfHeight)
                bars.addRect(CGRect(x: CGFloat(column), y: midY - height, width: 1, height: height * 2))
            }
            context.fill(bars, with: .color(isSelected ? selectedWaveColor : waveColor))
        }

        drawFadeWedges(for: clip, context: context, viewport: viewport, laneTop: laneTop, laneHeight: laneHeight)

        context.stroke(
            Path(roundedRect: clipRect, cornerSize: CGSize(width: 4, height: 4)),
            with: .color(isSelected ? .white : clipBorder),
            lineWidth: isSelected ? 2 : 1
        )

        if isSelected {
            drawTrimGrip(at: x0, laneTop: laneTop, laneHeight: laneHeight, context: context)
            drawTrimGrip(at: x1, laneTop: laneTop, laneHeight: laneHeight, context: context)
        }
    }

    /// A small vertical bar on a selected clip's edge marking where dragging trims rather than moves or fades it.
    private func drawTrimGrip(at x: CGFloat, laneTop: CGFloat, laneHeight: CGFloat, context: GraphicsContext) {
        let gripTop = laneTop + 22
        let gripBottom = laneTop + laneHeight - 6
        guard gripBottom > gripTop else { return }
        let grip = CGRect(x: x - 1.5, y: gripTop, width: 3, height: gripBottom - gripTop)
        context.fill(Path(roundedRect: grip, cornerSize: CGSize(width: 1.5, height: 1.5)), with: .color(.white.opacity(0.7)))
    }

    private func drawFadeWedges(
        for clip: TrackClip,
        context: GraphicsContext,
        viewport: WaveformViewport,
        laneTop: CGFloat,
        laneHeight: CGFloat
    ) {
        let midY = laneTop + laneHeight / 2
        let laneBottom = laneTop + laneHeight

        if clip.fadeInDuration > 0 {
            let x0 = viewport.x(for: clip.timelineStart)
            let x1 = viewport.x(for: clip.timelineStart + clip.fadeInDuration)
            fillWedge(context: context, points: [CGPoint(x: x0, y: laneTop), CGPoint(x: x1, y: laneTop), CGPoint(x: x0, y: midY)])
            fillWedge(context: context, points: [CGPoint(x: x0, y: laneBottom), CGPoint(x: x1, y: laneBottom), CGPoint(x: x0, y: midY)])
            let dot = CGRect(x: x0 - 5, y: laneTop + 3, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot), with: .color(fadeColor))
            context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }

        if clip.fadeOutDuration > 0 {
            let x0 = viewport.x(for: clip.timelineEnd - clip.fadeOutDuration)
            let x1 = viewport.x(for: clip.timelineEnd)
            fillWedge(context: context, points: [CGPoint(x: x1, y: laneTop), CGPoint(x: x0, y: laneTop), CGPoint(x: x1, y: midY)])
            fillWedge(context: context, points: [CGPoint(x: x1, y: laneBottom), CGPoint(x: x0, y: laneBottom), CGPoint(x: x1, y: midY)])
            let dot = CGRect(x: x1 - 5, y: laneTop + 3, width: 10, height: 10)
            context.fill(Path(ellipseIn: dot), with: .color(fadeColor))
            context.stroke(Path(ellipseIn: dot), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
    }

    private func fillWedge(context: GraphicsContext, points: [CGPoint]) {
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        context.fill(path, with: .color(background.opacity(0.75)))
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

/// The whole song at a glance with the zoomed viewport overlaid — both a map of where you are and a way to move.
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
    /// `m:ss.d`: precise enough to place a downbeat, short enough to fit a narrow field.
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

    /// Accepts what `precise` writes, plus a bare number of seconds, since typing "12" is the obvious thing to try.
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

/// Reaches the `NSWindow` behind a SwiftUI hierarchy, so a key monitor can tell this window's events from the booth's.
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

    /// Undo inside the editor works on the draft, one entry per gesture; applying puts a single step on the app's undo stack.
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
    /// Arrangement equivalent of `openingDraft` — what "Undo All" restores blades/moves/fades to.
    @State private var openingClips: [TrackClip] = []
    @State private var hasRecordedSessionUndo = false
    @State private var hasHydrated = false

    @State private var startText: String = ""
    @State private var endText: String = ""

    @State private var viewStart: Double = 0
    @State private var visibleDuration: Double = 1

    // MARK: Arrangement (blade / two lanes)
    // Empty means "not bladed yet" (flat draftStart/End/Fade fields apply); once bladed, this is the source of truth.
    @State private var draftClips: [TrackClip] = []
    @State private var selectedClipID: UUID?
    @State private var arrangementUndoStack: [[TrackClip]] = []
    @State private var arrangementRedoStack: [[TrackClip]] = []
    @State private var clipDragOriginalTimelineStart: Double?
    @State private var clipDragOriginalLane: Int?
    @State private var fadeDragClipID: UUID?
    @State private var trimDragClipID: UUID?
    @State private var arrangedDragKind: ArrangedDragKind?
    /// Which edge (if any) a clip drag is currently snapped to, so the haptic buzz fires once per snap, not per frame.
    @State private var lastSnapTarget: Double?
    /// Where the playhead sits on the arranged timeline when uncued, since `localPlayhead`'s file seconds don't match clip coordinates once moved.
    @State private var localArrangedPlayhead: Double = 0

    private enum ArrangedDragKind {
        case moveClip(clipID: UUID, originalTimelineStart: Double, originalLane: Int)
        case fadeIn(clipID: UUID)
        case fadeOut(clipID: UUID)
        case trimStart(clipID: UUID)
        case trimEnd(clipID: UUID)
    }

    @State private var dragMode: DragMode?
    @State private var dragAnchor: Double = 0
    /// Which notch a drag last ticked at, so feedback fires once per notch crossed, not every frame.
    @State private var lastHapticNotch: Int?
    /// Where the playhead sits when this song isn't cued; once cued, position comes from the player itself.
    @State private var localPlayhead: Double = 0
    @ObservedObject private var tutorialManager = TutorialManager.shared
    @State private var hostWindow: NSWindow?
    @State private var keyMonitor: Any?
    @State private var scrollMonitor: Any?
    /// Needed by the scroll handler to turn a scroll distance into a span of time.
    @State private var waveformWidth: CGFloat = 0
    /// Mouse position over the waveform in the active canvas's time coordinate, shown as a preview line for the blade.
    @State private var hoverTime: Double?
    /// Scoped to the waveform's bounds so this monitor doesn't swallow scrolls meant for the surrounding ScrollView.
    @State private var isHoveringWaveform = false

    // MARK: Metadata (merged in from the old separate "Metadata Editor" panel)
    @State private var editableTitle: String = ""
    @State private var editableArtist: String = ""
    @State private var localArtwork: NSImage? = nil
    /// Only a deliberate pick counts as custom art — art merely loaded from file tags shouldn't be duplicated into saves.
    @State private var didChooseArtwork: Bool = false
    @State private var tempoPercentage: Double = 0.0
    @State private var isEditingTempoText: Bool = false
    @State private var tempoTextInput: String = ""
    @State private var manualBPMText: String = ""
    @State private var isEditingEffectiveBPMText: Bool = false
    @State private var effectiveBPMTextInput: String = ""
    @State private var tempoKeyMonitor: Any?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    // Spotify audio never reaches the app, so start/end are typed timestamps mirroring draftStart/draftEnd instead of a waveform drag.
    @State private var spotifyStartMinString: String = "0"
    @State private var spotifyStartSecString: String = "00"
    @State private var spotifyEndMinString: String = "0"
    @State private var spotifyEndSecString: String = "00"

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

    /// The song as it would be if the draft were applied, so previewing uses the same code path as real playback.
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

    /// Converts the engine's tempo-scaled played seconds back to the waveform's file seconds (multiplying, not dividing).
    private var playheadTime: Double {
        guard isLiveTrack, let live = player.currentTrack else { return localPlayhead }
        return live.startTime + player.currentTime * live.speedMultiplier
    }

    /// True once bladed; the two-lane arranged waveform view then replaces the single trim waveform.
    private var isArranged: Bool { !draftClips.isEmpty }

    /// Like `playheadTime` but for the arranged view, where clips use their own zero-based `timelineStart`, not the file's.
    private var arrangedPlayheadTime: Double {
        guard isLiveTrack, let live = player.currentTrack else { return localArrangedPlayhead }
        return player.currentTime * live.speedMultiplier
    }

    private func moveArrangedPlayhead(to timelineAbsolute: Double) {
        let maxTimeline = effectiveClips.map(\.timelineEnd).max() ?? timelineAbsolute
        let bounded = max(0, min(timelineAbsolute, maxTimeline))
        localArrangedPlayhead = bounded

        guard isLiveTrack, let live = player.currentTrack else { return }
        player.seek(to: max(0, bounded / live.speedMultiplier))
    }

    /// What the booth's transport shows: time since the start point scaled by tempo, i.e. played length not file position.
    private var playedTime: Double {
        guard let track else { return 0 }
        return max(0, (playheadTime - track.startTime) / track.speedMultiplier)
    }

    /// A skipped song can't be cued, since the transport would step over it and play a different song than shown.
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

    // MARK: Metadata

    /// Spotify audio never reaches the app, so this mode swaps the waveform section for typed start/end timestamps.
    private var isSpotifyTrack: Bool {
        track?.source == .spotify
    }

    private var baseBPMValue: Double? {
        guard let value = Double(manualBPMText), value > 0 else { return nil }
        return value
    }

    private var effectiveBPMValue: Double? {
        guard let base = baseBPMValue else { return nil }
        return base * (1 + tempoPercentage / 100)
    }

    /// Slider granularity: whole-BPM steps once Show Tempo is on and a base BPM is set, else the default 0.5%.
    private var tempoSliderStep: Double {
        if player.showTempo, let base = baseBPMValue, base > 0 {
            return max(0.02, 100.0 / base)
        }
        return 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        metadataSection
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .tutorialAnchor("editor.metadata")
                            .id("editor.metadata")

                        Divider().background(Color(hex: "#242429")).padding(.top, 14)

                        if isSpotifyTrack {
                            spotifyTimestampSection
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                        } else {
                            waveformSection
                                .padding(.horizontal, 16)
                                .padding(.top, 14)
                                .tutorialAnchor("editor.waveform")
                                .id("editor.waveform")

                            zoomControls
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .tutorialAnchor("editor.zoom")
                                .id("editor.zoom")

                            Divider().background(Color(hex: "#242429")).padding(.top, 14)

                            if isArranged {
                                arrangementHelp
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                            }

                            VStack(alignment: .leading, spacing: 16) {
                                boundaryControls
                                    .tutorialAnchor("editor.boundary")
                                    .id("editor.boundary")
                                fadeControls
                                    .tutorialAnchor("editor.fade")
                                    .id("editor.fade")
                            }
                            .padding(16)
                        }
                    }
                }
                // The scrim highlights the real, unclipped frame of the current step's anchor --
                // if that section is scrolled out of the ScrollView's visible area, the ring
                // still draws at its true (offscreen) position, so this brings it into view first.
                .onChange(of: tutorialManager.stepIndex) { _, _ in
                    scrollToCurrentTutorialAnchor(using: scrollProxy)
                }
                .onChange(of: tutorialManager.activeContext) { _, newValue in
                    if newValue == .timingEditor || newValue == .timingEditorSpotify {
                        scrollToCurrentTutorialAnchor(using: scrollProxy)
                    }
                }
            }

            Divider().background(Color(hex: "#242429"))
            footer
                .tutorialAnchor("editor.footer")
        }
        .frame(minWidth: 900, idealWidth: 1080, minHeight: 660, idealHeight: 820)
        .background(Color(hex: "#0e0e10"))
        .foregroundColor(.white)
        .tutorialOverlayHost(for: [.timingEditor, .timingEditorSpotify])
        .background(WindowAccessor { window in
            // AppKit auto-focuses the start-time field on open, which silently ate spacebar/zoom shortcuts until dismissed.
            if hostWindow == nil { window?.makeFirstResponder(nil) }
            hostWindow = window
        })
        // Tour steps edit the real track (not a sandbox copy), so leaving this editor for any reason reverts what they did.
        .onChange(of: tutorialManager.activeContext) { oldValue, newValue in
            let wasTouring = oldValue == .timingEditor || oldValue == .timingEditorSpotify
            let isStillTouring = newValue == .timingEditor || newValue == .timingEditorSpotify
            if wasTouring, !isStillTouring {
                undoAllChanges()
            }
        }
        // Downloading a Spotify track's audio while this editor is already open flips
        // `isSpotifyTrack` false mid-session -- `onAppear` already ran back when it was still
        // true (skipping the load), so nothing pulled in a waveform until this fires.
        .onChange(of: isSpotifyTrack) { wasSpotify, isSpotify in
            if wasSpotify, !isSpotify { loadWaveform() }
        }
        .onAppear {
            hydrate()
            if !isSpotifyTrack { loadWaveform() }
            installKeyMonitor()
            installScrollMonitor()
            installTempoKeyMonitor()
            DispatchQueue.main.async {
                TutorialManager.shared.startIfNeverSeen(isSpotifyTrack ? .timingEditorSpotify : .timingEditor)
            }
        }
        // The Start/End fields are in played seconds, so they must track the tempo live as it's dragged, not just on release.
        .onChange(of: tempoPercentage) { _, _ in
            guard hasHydrated else { return }
            startText = scaledText(draftStart)
            endText = scaledText(draftEnd)
        }
        .onDisappear {
            removeMonitors()
            removeTempoKeyMonitor()
            // Closing mid-tour still needs to discard the tour's edits, since `finish()` alone won't trigger the onChange above.
            if tutorialManager.activeContext == .timingEditor || tutorialManager.activeContext == .timingEditorSpotify {
                undoAllChanges()
                TutorialManager.shared.finish()
            }
            // Edits commit as they're made; this is just a backstop to flush the debounced library write on close.
            apply()
            saveMetadataModifications()
            player.flushPendingTrackSave()
        }
        .alert(
            "Couldn't Export",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TRACK EDITOR")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "#71717a"))
                    .tracking(0.5)
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
                if !isSpotifyTrack, tempoPercentage != 0 {
                    // Reads the live slider state, not the saved track, so this tracks the tempo live as it's dragged.
                    Text(String(
                        format: "plays as %@ at %+.1f%%",
                        TimingFormat.precise(regionLength / draftSpeedMultiplier),
                        tempoPercentage
                    ))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#71717a"))
                }
            }
        }
        .padding(16)
    }

    /// The live, possibly-still-dragging tempo that duration/timestamp readouts scale against so they update live.
    private var draftSpeedMultiplier: Double {
        let multiplier = 1.0 + (isSpotifyTrack ? 0 : tempoPercentage) / 100.0
        return max(0.25, min(multiplier, 2.0))
    }

    /// The Start/End fields use played (tempo-scaled) seconds like the transport; converted at the boundary from draftStart/draftEnd's file seconds.
    private func scaledText(_ fileSeconds: Double) -> String {
        TimingFormat.precise(fileSeconds / draftSpeedMultiplier)
    }

    private func unscaledSeconds(_ playedSeconds: Double) -> Double {
        playedSeconds * draftSpeedMultiplier
    }

    private var regionLength: Double {
        max(0, draftEnd - draftStart)
    }

    private var regionSummary: String {
        "\(TimingFormat.precise(draftStart)) → \(TimingFormat.precise(draftEnd))  (\(TimingFormat.precise(regionLength)))"
    }

    // MARK: Metadata (merged in from the old separate "Metadata Editor" panel)

    private var metadataSection: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                Group {
                    if let art = localArtwork {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(hex: "#18181b")
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 26))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(width: 88, height: 88)
                .cornerRadius(8)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture { importCoverArtImage() }
                .pointingHandCursor()

                Text("Click to change art")
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("SONG TITLE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        TextField("Title", text: $editableTitle)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveMetadataModifications)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ARTIST NAME")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        TextField("Artist", text: $editableArtist)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveMetadataModifications)
                    }
                }

                // Tempo warp only applies to locally-played audio; Spotify plays through its own API with no DSP of ours.
                if !isSpotifyTrack {
                    tempoControls
                        .tutorialAnchor("editor.tempo")
                }
            }
        }
        .onChange(of: editableTitle) { _, _ in TutorialManager.shared.reportAction(.editorMetadataEdited) }
        .onChange(of: editableArtist) { _, _ in TutorialManager.shared.reportAction(.editorMetadataEdited) }
        .onChange(of: tempoPercentage) { _, _ in TutorialManager.shared.reportAction(.editorTempoChanged) }
    }

    private var tempoControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("TEMPO ADJUSTMENT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                Spacer()

                if isEditingTempoText {
                    TextField("e.g. -8.9", text: $tempoTextInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .font(.system(size: 11, weight: .bold))
                        .onSubmit { commitTempoTextInput() }
                        .onExitCommand {
                            isEditingTempoText = false
                            tempoTextInput = ""
                        }
                } else {
                    Text(String(format: "%+.1f%%", tempoPercentage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tempoPercentage == 0 ? .gray : .blue)
                        .help("Click to type a custom tempo value")
                        .onTapGesture {
                            tempoTextInput = String(format: "%.1f", tempoPercentage)
                            isEditingTempoText = true
                        }
                }
            }

            HStack(spacing: 8) {
                Text("BASE BPM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)
                TextField("blank", text: $manualBPMText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)
                    .font(.system(size: 11))
                    .onSubmit(saveMetadataModifications)

                if baseBPMValue != nil {
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)

                    if isEditingEffectiveBPMText {
                        TextField("bpm", text: $effectiveBPMTextInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 55)
                            .font(.system(size: 11, weight: .bold))
                            .onSubmit { commitEffectiveBPMTextInput() }
                            .onExitCommand {
                                isEditingEffectiveBPMText = false
                                effectiveBPMTextInput = ""
                            }
                    } else if let effective = effectiveBPMValue {
                        Text("\(Int(effective.rounded())) BPM")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.blue)
                            .help("Click to type a target BPM")
                            .onTapGesture {
                                effectiveBPMTextInput = String(Int(effective.rounded()))
                                isEditingEffectiveBPMText = true
                            }
                    }
                }
                Spacer()
            }

            TicklessSlider(
                value: $tempoPercentage,
                range: -25...25,
                step: tempoSliderStep,
                onEditingChanged: { isEditing in
                    if !isEditing {
                        saveMetadataModifications()
                        HapticFeedback.perform(.levelChange)
                    }
                }
            )
            .accentColor(.blue)

            HStack {
                Text("Slower")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Spacer()
                Button("Reset") {
                    tempoPercentage = 0.0
                    saveMetadataModifications()
                    HapticFeedback.perform(.levelChange)
                }
                .font(.system(size: 9))
                .buttonStyle(.plain)
                .pointingHandCursor()
                Spacer()
                Text("Faster")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: Spotify (no waveform -- typed timestamps instead)

    private var spotifyTimestampSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Spotify audio never reaches the app, so start and end are set by typed "
                 + "timestamp instead of a waveform. Use \"Download File\" from the queue's "
                 + "+ menu to pull the audio locally for the full waveform editor.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#a3a3ac"))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                spotifyTimestampField(
                    title: "START TIMESTAMP",
                    minutes: $spotifyStartMinString,
                    seconds: $spotifyStartSecString,
                    edge: .start
                )
                spotifyTimestampField(
                    title: "END TIMESTAMP",
                    minutes: $spotifyEndMinString,
                    seconds: $spotifyEndSecString,
                    edge: .end
                )
            }
            .tutorialAnchor("editor.spotifyTimestamps")
            .id("editor.spotifyTimestamps")

            downloadSpotifyAudioButton
                .tutorialAnchor("editor.spotifyDownload")
                .id("editor.spotifyDownload")
        }
    }

    /// Minutes/seconds plus a five-second audition, since a Spotify track can't be drawn and hearing it is the only check.
    private func spotifyTimestampField(
        title: String,
        minutes: Binding<String>,
        seconds: Binding<String>,
        edge: SpotifyPreviewEdge
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.gray)

            HStack(spacing: 6) {
                TextField("Min", text: minutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 50)
                    .onSubmit(commitSpotifyTimestamps)
                Text(":")
                    .font(.system(size: 12, weight: .bold))
                TextField("Sec", text: seconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .onSubmit(commitSpotifyTimestamps)

                Button {
                    previewSpotifyEdge(edge)
                } label: {
                    Image(systemName: player.spotifyPreviewEdge == edge
                          ? "stop.circle.fill"
                          : "play.circle.fill")
                        .font(.system(size: 17))
                        .foregroundColor(player.spotifyPreviewEdge == edge
                                         ? Color(hex: "#f97316")
                                         : Color(hex: "#3478f6"))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(edge == .start
                      ? "Play the first 5 seconds from this timestamp"
                      : "Play the 5 seconds leading up to this timestamp")
            }
        }
    }

    private func commitSpotifyTimestamps() {
        let start = max(0, (Double(spotifyStartMinString) ?? 0) * 60 + (Double(spotifyStartSecString) ?? 0))
        let end = (Double(spotifyEndMinString) ?? 0) * 60 + (Double(spotifyEndSecString) ?? 0)
        edit {
            setStart(start)
            setEnd(end > start ? end : (track?.duration ?? end))
        }
    }

    /// Sent the values currently in the fields, not the saved ones, so a timestamp can be checked before committing.
    private func previewSpotifyEdge(_ edge: SpotifyPreviewEdge) {
        guard let track else { return }

        let start = max(0, (Double(spotifyStartMinString) ?? 0) * 60 + (Double(spotifyStartSecString) ?? 0))
        let end = (Double(spotifyEndMinString) ?? 0) * 60 + (Double(spotifyEndSecString) ?? 0)

        player.previewSpotifyEdge(
            edge,
            of: track,
            start: start,
            end: end > start ? end : track.duration
        )
        TutorialManager.shared.reportAction(.editorPreviewedSpotifyEdge)
    }

    private var isDownloadingThisTrack: Bool {
        player.spotifyDownloadTrackID == trackID
    }

    private var downloadButtonLabel: String {
        isDownloadingThisTrack ? "Downloading…" : "Download File"
    }

    /// Finds the song on YouTube, downloads its audio, and converts the track to local, unlocking the waveform editor.
    private var downloadSpotifyAudioButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                saveMetadataModifications()
                player.downloadSpotifyTrackAudio(trackID: trackID)
            } label: {
                HStack(spacing: 8) {
                    if isDownloadingThisTrack {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(downloadButtonLabel)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color(hex: "#18181b"))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(hex: "#27272a"), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .disabled(player.spotifyDownloadTrackID != nil)
            .help("Look for this song on YouTube, download its audio, and switch this track over to the downloaded local file")

            if isDownloadingThisTrack, let statusMessage = player.spotifyStatusMessage {
                Text(statusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
    }

    // MARK: Metadata persistence / tempo key handling

    private func importCoverArtImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.begin { response in
            if response == .OK, let selectedURL = panel.url {
                if let imagePayload = NSImage(contentsOf: selectedURL) {
                    DispatchQueue.main.async {
                        self.localArtwork = imagePayload
                        self.didChooseArtwork = true
                        self.saveMetadataModifications()
                    }
                }
            }
        }
    }

    /// Commits first so export reflects what's on screen, then renders trim/fades/blade/tempo into a standalone file.
    private func beginExport() {
        guard let track, !isExporting else { return }
        apply()
        saveMetadataModifications()

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Audio]
        let safeName = "\(track.title) - \(track.artist) (Edited in the Dance Player App)"
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName).m4a"
        panel.message = "Choose where to save the edited audio."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isExporting = true
        Task {
            do {
                guard let exportedTrack = player.tracks.first(where: { $0.id == trackID }) else { return }
                try await player.exportEditedTrack(exportedTrack, to: destinationURL)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
            isExporting = false
        }
    }

    private func saveMetadataModifications() {
        guard let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let previousTempo = player.tracks[index].tempoPercentage

        var updated = player.tracks[index]
        updated.title = editableTitle
        updated.artist = editableArtist
        updated.artwork = localArtwork
        if didChooseArtwork { updated.hasCustomArtwork = true }
        if updated.source == .local {
            updated.tempoPercentage = tempoPercentage
        }
        updated.manualBPM = manualBPMText

        // Opening and closing without an edit shouldn't push a do-nothing undo entry.
        guard updated != player.tracks[index] else { return }

        if !hasRecordedSessionUndo {
            player.recordUndoSnapshot("Edit Track")
            hasRecordedSessionUndo = true
        }
        player.tracks[index] = updated

        if player.currentIndex == index {
            player.synchronizeActiveTrackSettings()
        }
        // Debounced, since `saveTrack` synchronously rewrites the whole library JSON and rapid edits were freezing the editor.
        player.saveTrackSoon(updated)

        // Time-stretching overshoots peaks, so gain must be re-derived against the stretched audio to avoid clipping.
        if updated.tempoPercentage != previousTempo {
            player.relevelGainForTempoChange(trackID: updated.id)
        }
    }

    private func commitTempoTextInput() {
        if let parsed = Double(tempoTextInput) {
            let clamped = max(-25, min(25, parsed))
            tempoPercentage = clamped
        }
        isEditingTempoText = false
        tempoTextInput = ""
        saveMetadataModifications()
        HapticFeedback.perform(.levelChange)
    }

    private func commitEffectiveBPMTextInput() {
        if let base = baseBPMValue, let target = Double(effectiveBPMTextInput), base > 0 {
            let impliedPercentage = ((target / base) - 1) * 100
            let clamped = max(-25, min(25, impliedPercentage))
            tempoPercentage = clamped
        }
        isEditingEffectiveBPMText = false
        effectiveBPMTextInput = ""
        saveMetadataModifications()
        HapticFeedback.perform(.levelChange)
    }

    /// Stands aside when a text field needs the arrow keys for its own purpose.
    private func installTempoKeyMonitor() {
        removeTempoKeyMonitor()
        tempoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isSpotifyTrack else { return event }

            // Arrow keys always carry `.function`/`.numericPad`, so only refuse modifiers that would mean something else.
            let modifiers = event.modifierFlags
            guard !modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control)
            else { return event }
            if hostWindow?.firstResponder is NSTextView { return event }

            let step = modifiers.contains(.shift) ? 0.5 : 1.0
            switch event.keyCode {
            case 123: // left arrow
                nudgeTempo(by: -step)
                return nil
            case 124: // right arrow
                nudgeTempo(by: step)
                return nil
            default:
                return event
            }
        }
    }

    private func removeTempoKeyMonitor() {
        if let tempoKeyMonitor { NSEvent.removeMonitor(tempoKeyMonitor) }
        tempoKeyMonitor = nil
    }

    private func nudgeTempo(by amount: Double) {
        let updated = max(-25, min(25, tempoPercentage + amount))
        guard updated != tempoPercentage else { return }

        tempoPercentage = updated
        saveMetadataModifications()
        HapticFeedback.perform(.levelChange)
    }

    // MARK: Waveform

    @ViewBuilder
    private var waveformSection: some View {
        VStack(spacing: 0) {
            if let waveform {
                GeometryReader { geometry in
                    if isArranged {
                        ArrangedWaveformCanvas(
                            waveform: waveform,
                            fileDuration: track?.duration ?? waveform.duration,
                            viewStart: viewStart,
                            visibleDuration: visibleDuration,
                            clips: effectiveClips,
                            selectedClipID: selectedClipID,
                            playhead: arrangedPlayheadTime,
                            isPlaying: isPlayingThisTrack,
                            laneCount: LocalPlaybackEngine.laneCount,
                            hoverTime: hoverTime
                        )
                        .contentShape(Rectangle())
                        .onAppear { waveformWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in waveformWidth = width }
                        .onContinuousHover { phase in
                            let laneHeight = geometry.size.height / CGFloat(LocalPlaybackEngine.laneCount)
                            switch phase {
                            case .active(let point):
                                let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: geometry.size.width)
                                hoverTime = viewport.time(for: point.x)
                                isHoveringWaveform = true
                                // A resize cursor over a clip's edges signals that dragging there trims, not moves, the piece.
                                switch hitTestArranged(at: point, viewport: viewport, laneHeight: laneHeight) {
                                case .trimStart, .trimEnd:
                                    NSCursor.resizeLeftRight.set()
                                default:
                                    NSCursor.arrow.set()
                                }
                            case .ended:
                                hoverTime = nil
                                isHoveringWaveform = false
                                NSCursor.arrow.set()
                            }
                        }
                        .gesture(arrangedDragGesture(width: geometry.size.width, laneHeight: geometry.size.height / CGFloat(LocalPlaybackEngine.laneCount)))
                    } else {
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
                            isPlaying: isPlayingThisTrack,
                            hoverTime: hoverTime
                        )
                        .contentShape(Rectangle())
                        .onAppear { waveformWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in waveformWidth = width }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: geometry.size.width)
                                hoverTime = viewport.time(for: point.x)
                                isHoveringWaveform = true
                            case .ended:
                                hoverTime = nil
                                isHoveringWaveform = false
                            }
                        }
                        .gesture(dragGesture(width: geometry.size.width))
                        .gesture(MagnificationGesture().onChanged { scale in
                            // Pinch reads as a ratio against the gesture's start.
                            zoom(toVisible: visibleDuration / scale, anchorTime: zoomAnchorTime)
                        })
                    }
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
                    TutorialManager.shared.reportAction(.editorTrimmed)
                case .end:
                    setEnd(time)
                    tickHaptics(draftEnd, every: 1)
                    TutorialManager.shared.reportAction(.editorTrimmed)
                case .fadeIn:
                    draftFadeIn = clampFade(time - draftStart)
                    // A quarter second, not a whole one, since fades are short and per-second ticks would feel too coarse.
                    tickHaptics(draftFadeIn, every: 0.25)
                case .fadeOut:
                    draftFadeOut = clampFade(stopTime - time)
                    tickHaptics(draftFadeOut, every: 0.25)
                case .pan:
                    // The grabbed instant stays under the pointer, making the drag feel like moving paper, not a scrollbar.
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

    /// One tick per notch crossed, giving a drag a sense of scale and, at close zoom, of how far it's actually moved.
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
        // Ties go to the nearer boundary so the two can still be dragged apart when zoomed out far enough to overlap.
        if abs(point.x - startX) <= grabRadius || abs(point.x - endX) <= grabRadius {
            return abs(point.x - startX) <= abs(point.x - endX) ? .start : .end
        }

        return .pan
    }

    // MARK: Arranged waveform gestures

    /// Snaps a dragged clip's edge onto another clip's edge (or timeline start) within a few pixels, buzzing once per lock.
    private func snappedTimelineStart(for clipID: UUID, proposedStart: Double, pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return proposedStart }
        let snapThresholdSeconds = 8.0 / pixelsPerSecond

        let duration = effectiveClips.first(where: { $0.id == clipID })?.sourceDuration ?? 0
        let proposedEnd = proposedStart + duration

        var candidateEdges: [Double] = [0]
        for other in effectiveClips where other.id != clipID {
            candidateEdges.append(other.timelineStart)
            candidateEdges.append(other.timelineEnd)
        }

        var best: (impliedStart: Double, distance: Double)?
        for edge in candidateEdges {
            let startDistance = abs(proposedStart - edge)
            if best == nil || startDistance < best!.distance {
                best = (edge, startDistance)
            }
            let endDistance = abs(proposedEnd - edge)
            if best == nil || endDistance < best!.distance {
                best = (edge - duration, endDistance)
            }
        }

        guard let best, best.distance <= snapThresholdSeconds else {
            lastSnapTarget = nil
            return proposedStart
        }

        if lastSnapTarget != best.impliedStart {
            lastSnapTarget = best.impliedStart
            HapticFeedback.perform(.alignment)
        }
        return max(0, best.impliedStart)
    }

    private func hitTestArranged(at point: CGPoint, viewport: WaveformViewport, laneHeight: CGFloat) -> ArrangedDragKind? {
        guard laneHeight > 0 else { return nil }
        let lane = max(0, min(LocalPlaybackEngine.laneCount - 1, Int(point.y / laneHeight)))
        let time = viewport.time(for: point.x)

        guard let clip = effectiveClips.first(where: {
            $0.lane == lane && $0.timelineStart <= time && time <= $0.timelineEnd
        }) else { return nil }

        // Fade handles live in a corner band at the top of the clip, same idea as `fadeHandleBandHeight` elsewhere.
        let cornerGrabRadius: CGFloat = 12
        let bandHeight: CGFloat = 20
        let laneLocalY = point.y - CGFloat(clip.lane) * laneHeight
        let x0 = viewport.x(for: clip.timelineStart)
        let x1 = viewport.x(for: clip.timelineEnd)
        if laneLocalY <= bandHeight {
            if abs(point.x - x0) <= cornerGrabRadius { return .fadeIn(clipID: clip.id) }
            if abs(point.x - x1) <= cornerGrabRadius { return .fadeOut(clipID: clip.id) }
        }

        // Below the fade band, the same edges trim instead: pull outward to reveal more source, inward to cut into it.
        let edgeGrabWidth: CGFloat = 8
        if abs(point.x - x0) <= edgeGrabWidth { return .trimStart(clipID: clip.id) }
        if abs(point.x - x1) <= edgeGrabWidth { return .trimEnd(clipID: clip.id) }

        return .moveClip(clipID: clip.id, originalTimelineStart: clip.timelineStart, originalLane: clip.lane)
    }

    private func arrangedDragGesture(width: CGFloat, laneHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: width)
                if arrangedDragKind == nil {
                    arrangedDragKind = hitTestArranged(at: value.startLocation, viewport: viewport, laneHeight: laneHeight)
                }

                // Defers mutation until the gesture actually moves, so a plain click isn't read as the start of a clip move.
                let hasMoved = abs(value.translation.width) >= 3 || abs(value.translation.height) >= 3
                guard hasMoved else { return }

                switch arrangedDragKind {
                case .moveClip(let clipID, let originalTimelineStart, let originalLane):
                    if clipDragOriginalTimelineStart == nil {
                        clipDragOriginalTimelineStart = originalTimelineStart
                        clipDragOriginalLane = originalLane
                        recordArrangementUndo()
                        selectedClipID = clipID
                    }
                    let deltaSeconds = Double(value.translation.width / width) * visibleDuration
                    let deltaLane = laneHeight > 0 ? Int((value.translation.height / laneHeight).rounded()) : 0
                    let rawStart = max(0, (clipDragOriginalTimelineStart ?? originalTimelineStart) + deltaSeconds)
                    let newStart = snappedTimelineStart(
                        for: clipID,
                        proposedStart: rawStart,
                        pixelsPerSecond: Double(width) / visibleDuration
                    )
                    let newLane = (clipDragOriginalLane ?? originalLane) + deltaLane
                    moveClip(id: clipID, toLane: newLane, timelineStart: newStart)

                case .fadeIn(let clipID):
                    if fadeDragClipID == nil {
                        fadeDragClipID = clipID
                        recordArrangementUndo()
                        selectedClipID = clipID
                    }
                    guard let clip = effectiveClips.first(where: { $0.id == clipID }) else { return }
                    let time = viewport.time(for: value.location.x)
                    setFade(forClip: clipID, fadeIn: max(0, time - clip.timelineStart))

                case .fadeOut(let clipID):
                    if fadeDragClipID == nil {
                        fadeDragClipID = clipID
                        recordArrangementUndo()
                        selectedClipID = clipID
                    }
                    guard let clip = effectiveClips.first(where: { $0.id == clipID }) else { return }
                    let time = viewport.time(for: value.location.x)
                    setFade(forClip: clipID, fadeOut: max(0, clip.timelineEnd - time))

                case .trimStart(let clipID):
                    if trimDragClipID == nil {
                        trimDragClipID = clipID
                        recordArrangementUndo()
                        selectedClipID = clipID
                    }
                    trimClipStart(
                        id: clipID,
                        toTimelineTime: viewport.time(for: value.location.x),
                        pixelsPerSecond: Double(width) / visibleDuration
                    )

                case .trimEnd(let clipID):
                    if trimDragClipID == nil {
                        trimDragClipID = clipID
                        recordArrangementUndo()
                        selectedClipID = clipID
                    }
                    trimClipEnd(
                        id: clipID,
                        toTimelineTime: viewport.time(for: value.location.x),
                        pixelsPerSecond: Double(width) / visibleDuration
                    )

                case nil:
                    break
                }
            }
            .onEnded { value in
                let isClick = abs(value.translation.width) < 3 && abs(value.translation.height) < 3
                if isClick {
                    // Nothing was mutated in onChanged, so this just moves the playhead here and optionally selects the clip under it.
                    let viewport = WaveformViewport(start: viewStart, visible: visibleDuration, width: width)
                    moveArrangedPlayhead(to: viewport.time(for: value.location.x))
                    if case .moveClip(let clipID, _, _) = arrangedDragKind {
                        selectedClipID = clipID
                    }
                } else {
                    switch arrangedDragKind {
                    case .moveClip:
                        commitClipMove()
                    case .fadeIn, .fadeOut, .trimStart, .trimEnd:
                        applyArrangement()
                    case nil:
                        break
                    }
                }
                clipDragOriginalTimelineStart = nil
                clipDragOriginalLane = nil
                fadeDragClipID = nil
                trimDragClipID = nil
                arrangedDragKind = nil
                lastSnapTarget = nil
            }
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

            Divider().frame(height: 18)

            Button {
                bladeAtPlayhead()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                    Text("Blade")
                }
            }
            .buttonStyle(.bordered)
            .pointingHandCursor()
            .keyboardShortcut("b", modifiers: .command)
            .help("Split the piece under the playhead into two, right there (⌘B)")

            if isArranged, let selectedClipID {
                Button(role: .destructive) {
                    deleteClip(id: selectedClipID, closeGap: !NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .keyboardShortcut(.delete, modifiers: [])
                .help("Remove the selected piece and close the gap (⌫) — hold ⌥ to leave silence in its place instead")
            }

            Spacer()

            Text(String(format: "%@ visible", TimingFormat.precise(visibleDuration)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "#71717a"))
        }
        .font(.system(size: 11))
    }

    /// 0 shows the whole song, 1 the closest zoom; logarithmic since a linear slider wastes travel on the wide end.
    private var zoomFraction: Double {
        guard let fileDuration = track?.duration, fileDuration > Self.minimumVisibleDuration else { return 0 }
        let ratio = Self.minimumVisibleDuration / fileDuration
        return log(visibleDuration / fileDuration) / log(ratio)
    }

    private func setZoomFraction(_ fraction: Double) {
        guard let fileDuration = track?.duration, fileDuration > Self.minimumVisibleDuration else { return }
        let ratio = Self.minimumVisibleDuration / fileDuration
        let target = fileDuration * pow(ratio, max(0, min(1, fraction)))
        zoom(toVisible: target, anchorTime: zoomAnchorTime)
    }

    /// Zoom centers on the playhead when visible (keeping the relevant spot in frame), else falls back to the view's center.
    private var zoomAnchorTime: Double {
        let playhead = isArranged ? arrangedPlayheadTime : playheadTime
        return (playhead >= viewStart && playhead <= viewStart + visibleDuration)
            ? playhead
            : viewStart + visibleDuration / 2
    }

    private func zoomStep(factor: Double) {
        zoom(toVisible: visibleDuration * factor, anchorTime: zoomAnchorTime)
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

    private var arrangementHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("This song has been bladed into \(effectiveClips.count) piece\(effectiveClips.count == 1 ? "" : "s").")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
            Text("Drag a piece above to move it in time or onto the other lane — a piece that overlaps the other lane's in time plays together with it, for a crossfade. Drag a piece's top corners to fade it in or out, or its left/right edges to trim it. Select a piece and press ⌫ to remove it and close the gap, or ⌥⌫ to leave silence in its place instead.")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#71717a"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Boundary and fade controls

    private var boundaryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("TRIM")

            boundaryRow(
                title: "Start",
                text: $startText,
                commit: { edit { setStart(TimingFormat.parse(startText).map(unscaledSeconds) ?? draftStart) } },
                nudge: { amount in edit { setStart(draftStart + unscaledSeconds(amount)) } },
                setToPlayhead: { edit { setStart(playheadTime) } }
            )

            boundaryRow(
                title: "End",
                text: $endText,
                commit: { edit { setEnd(TimingFormat.parse(endText).map(unscaledSeconds) ?? draftEnd) } },
                nudge: { amount in edit { setEnd(draftEnd + unscaledSeconds(amount)) } },
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

            if !isSpotifyTrack {
                Button {
                    beginExport()
                } label: {
                    HStack(spacing: 6) {
                        if isExporting {
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                        }
                        Text(isExporting ? "Exporting…" : "Download File")
                    }
                }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(isExporting)
                .help("Save the edited audio -- trim, fades, tempo, and all -- as a standalone file with cover art and dance style tagged in")
            }

            Button("Undo All") { undoAllChanges() }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(!(hasSessionChanges || hasArrangementChanges))
                .help("Put everything — start, end, fades, and any blades or moves — back to how it opened")

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
        startText = scaledText(draftStart)
    }

    private func setEnd(_ proposed: Double) {
        guard let track else { return }
        draftEnd = min(track.duration, max(proposed, draftStart + 0.25))
        endText = scaledText(draftEnd)
    }

    /// Where the audio actually stops, ignoring a silent tail — the same -70 dB boundary the importer's trailing-silence scan uses.
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

    /// Called before a gesture or button changes anything, at the start of a drag, so one drag is one undo entry.
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

    /// Whether any blade/move/fade edit has been made to the arrangement since the editor opened.
    private var hasArrangementChanges: Bool { draftClips != openingClips }

    private static let scrollableTutorialAnchors: Set<String> = [
        "editor.metadata", "editor.waveform", "editor.zoom", "editor.boundary", "editor.fade",
        "editor.spotifyTimestamps", "editor.spotifyDownload"
    ]

    /// Scrolls the current tutorial step's anchor into view, since the scrim highlights a
    /// section's true frame even when it's currently clipped out of the ScrollView's viewport.
    private func scrollToCurrentTutorialAnchor(using proxy: ScrollViewProxy) {
        guard tutorialManager.activeContext == .timingEditor || tutorialManager.activeContext == .timingEditorSpotify,
              let anchorID = tutorialManager.currentStep?.anchorID,
              Self.scrollableTutorialAnchors.contains(anchorID) else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(anchorID, anchor: .center)
        }
    }

    /// Resets both the simple edits and the arrangement to how they were on open, in one button instead of several.
    private func undoAllChanges() {
        guard hasSessionChanges || hasArrangementChanges else { return }
        if let openingDraft, openingDraft != currentDraft {
            recordDraftUndo()
            restoreDraft(openingDraft)
        }
        if hasArrangementChanges {
            recordArrangementUndo()
            draftClips = openingClips
            applyArrangement()
        }
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
        startText = scaledText(draftStart)
        endText = scaledText(draftEnd)
        HapticFeedback.perform(.levelChange)
        apply()
    }

    private func hydrate(force: Bool = false) {
        guard let track, !hasHydrated || force else { return }

        // Tempo first, since `scaledText` reads it, and a default of 0 would show file seconds instead of played seconds.
        if !hasHydrated {
            hydrateMetadataFields(for: track)
        }

        draftStart = track.startTime
        draftEnd = track.resolvedEndTime
        draftFadeIn = track.fadeInDuration
        draftFadeOut = track.fadeOutDuration
        startText = scaledText(draftStart)
        endText = scaledText(draftEnd)
        draftClips = track.arrangement

        spotifyStartMinString = String(Int(draftStart) / 60)
        spotifyStartSecString = String(format: "%02d", Int(draftStart) % 60)
        let endSeconds = Int(draftEnd)
        spotifyEndMinString = String(endSeconds / 60)
        spotifyEndSecString = String(format: "%02d", endSeconds % 60)

        if !hasHydrated {
            visibleDuration = max(Self.minimumVisibleDuration, track.duration)
            viewStart = 0
            localPlayhead = track.startTime
            openingDraft = currentDraft
            openingClips = draftClips
            hasHydrated = true
        }
    }

    private func hydrateMetadataFields(for track: Track) {
        editableTitle = track.title
        editableArtist = track.artist
        localArtwork = track.artwork
        tempoPercentage = track.tempoPercentage
        manualBPMText = track.manualBPM

        // Decoding is the slow part of opening the waveform, so it starts as soon as the DJ looks at the song, not on render.
        if track.source == .local {
            WaveformCache.shared.prewarm(url: track.url)
        }
    }

    private func apply() {
        // Guarded so repeated play presses don't stack undo entries, and closing an untouched editor isn't itself an edit.
        guard hasUnsavedChanges,
              let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }

        // Once per editor session, not per nudge: working on a song is one thing done, and one thing to undo.
        if !hasRecordedSessionUndo {
            player.recordUndoSnapshot("Edit Track")
            hasRecordedSessionUndo = true
        }

        let previousStart = player.tracks[index].startTime

        var updated = player.tracks[index]
        updated.startTime = draftStart
        // An end at the file's own end is stored as "no end", so a re-import with a new duration isn't left trimmed short.
        updated.endTime = draftEnd < updated.duration ? draftEnd : nil
        updated.fadeInDuration = draftFadeIn
        updated.fadeOutDuration = draftFadeOut
        player.tracks[index] = updated

        if player.currentIndex == index {
            player.synchronizeActiveTrackSettings()
            player.recueForTrimChange(previousStartTime: previousStart)
        }

        // Debounced since this runs on every handle release and slider move and a library write isn't cheap; flushed on close.
        player.saveTrackSoon(updated)
        HapticFeedback.perform(.levelChange)
    }

    // MARK: Arrangement editing (blade / two lanes)

    private func recordArrangementUndo() {
        arrangementUndoStack.append(draftClips)
        arrangementRedoStack.removeAll()
    }

    private func undoArrangement() {
        guard let previous = arrangementUndoStack.popLast() else { return }
        arrangementRedoStack.append(draftClips)
        draftClips = previous
        applyArrangement()
    }

    private func redoArrangement() {
        guard let next = arrangementRedoStack.popLast() else { return }
        arrangementUndoStack.append(draftClips)
        draftClips = next
        applyArrangement()
    }

    private func applyArrangement() {
        guard let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        if !hasRecordedSessionUndo {
            player.recordUndoSnapshot("Edit Track")
            hasRecordedSessionUndo = true
        }

        var updated = player.tracks[index]
        updated.arrangement = draftClips
        player.tracks[index] = updated

        if player.currentIndex == index {
            player.synchronizeActiveTrackSettings()
            // A blade/delete/move/fade changes what's audible at a moment, so playback must re-sync or it'd hear the old schedule.
            player.refreshLiveArrangement(updated.resolvedArrangement, newDuration: updated.arrangedTimelineDuration)
        }
        player.saveTrackSoon(updated)
        HapticFeedback.perform(.levelChange)
    }

    /// Splits the clip under the playhead in two; the first blade converts a flat track into an explicit arrangement.
    private func bladeAtPlayhead() {
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        // Pre-arrangement, timeline zero coincides with `draftStart`, so this search works in timeline coordinates either way.
        let timelinePoint = isArranged ? arrangedPlayheadTime : (playheadTime - draftStart)

        guard let splitIndex = clips.firstIndex(where: {
            $0.timelineStart + 0.05 < timelinePoint && timelinePoint < $0.timelineEnd - 0.05
        }) else { return }

        recordArrangementUndo()

        let original = clips[splitIndex]
        // The clip may have moved since, so the timeline split point must be mapped back to a source-file point to split the audio.
        let sourceSplitPoint = original.sourceStart + (timelinePoint - original.timelineStart)
        let first = TrackClip(
            lane: original.lane,
            sourceStart: original.sourceStart,
            sourceEnd: sourceSplitPoint,
            timelineStart: original.timelineStart,
            fadeInDuration: original.fadeInDuration,
            fadeOutDuration: 0
        )
        let second = TrackClip(
            lane: original.lane,
            sourceStart: sourceSplitPoint,
            sourceEnd: original.sourceEnd,
            timelineStart: timelinePoint,
            fadeInDuration: 0,
            fadeOutDuration: original.fadeOutDuration
        )
        clips.replaceSubrange(splitIndex...splitIndex, with: [first, second])
        draftClips = clips
        selectedClipID = second.id
        applyArrangement()
        TutorialManager.shared.reportAction(.editorBladed)
    }

    /// The current arrangement, synthesizing the implicit single clip if unbladed so the UI always has something to show.
    private var effectiveClips: [TrackClip] {
        draftClips.isEmpty ? [singleImplicitClip] : draftClips
    }

    /// A fixed id, not a fresh UUID per evaluation — a changing id on every SwiftUI recompute would break ForEach and id-based lookups mid-drag.
    private static let implicitClipID = UUID()

    private var singleImplicitClip: TrackClip {
        TrackClip(
            id: Self.implicitClipID,
            lane: 0,
            sourceStart: draftStart,
            sourceEnd: draftEnd,
            timelineStart: 0,
            fadeInDuration: draftFadeIn,
            fadeOutDuration: draftFadeOut
        )
    }

    private func moveClip(id: UUID, toLane lane: Int, timelineStart: Double) {
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].lane = max(0, min(lane, LocalPlaybackEngine.laneCount - 1))
        clips[index].timelineStart = max(0, timelineStart)
        draftClips = clips
    }

    private func commitClipMove() {
        applyArrangement()
    }

    /// Minimum length a clip can be trimmed to, matching `setStart`/`setEnd`'s bar in the simple single-clip editor.
    private static let minimumClipDuration: Double = 0.25

    /// The single-edge version of `snappedTimelineStart`, for trimming rather than moving; buzzes once per newly-locked edge.
    private func snappedEdgeTime(near proposedTime: Double, excludingClipID: UUID, pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return proposedTime }
        let snapThresholdSeconds = 8.0 / pixelsPerSecond

        var candidateEdges: [Double] = [0]
        for other in effectiveClips where other.id != excludingClipID {
            candidateEdges.append(other.timelineStart)
            candidateEdges.append(other.timelineEnd)
        }

        guard let nearest = candidateEdges.min(by: { abs($0 - proposedTime) < abs($1 - proposedTime) }),
              abs(nearest - proposedTime) <= snapThresholdSeconds
        else {
            lastSnapTarget = nil
            return proposedTime
        }

        if lastSnapTarget != nearest {
            lastSnapTarget = nearest
            HapticFeedback.perform(.alignment)
        }
        return nearest
    }

    /// Drags the clip's left edge, moving timeline start and source start together so the right edge doesn't budge.
    private func trimClipStart(id: UUID, toTimelineTime rawProposedTime: Double, pixelsPerSecond: Double) {
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        let proposedTime = snappedEdgeTime(near: rawProposedTime, excludingClipID: id, pixelsPerSecond: pixelsPerSecond)
        let maxDelta = clip.sourceDuration - Self.minimumClipDuration
        let delta = max(-clip.sourceStart, min(proposedTime - clip.timelineStart, maxDelta))
        clips[index].sourceStart = clip.sourceStart + delta
        clips[index].timelineStart = clip.timelineStart + delta
        clips[index].fadeInDuration = min(clips[index].fadeInDuration, clips[index].sourceDuration / 2)
        draftClips = clips
    }

    /// Drags the clip's right edge to cut into or reveal more of the source's end; the timeline start stays put.
    private func trimClipEnd(id: UUID, toTimelineTime rawProposedTime: Double, pixelsPerSecond: Double) {
        guard let track else { return }
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        let proposedTime = snappedEdgeTime(near: rawProposedTime, excludingClipID: id, pixelsPerSecond: pixelsPerSecond)
        let minDelta = -(clip.sourceDuration - Self.minimumClipDuration)
        let maxDelta = track.duration - clip.sourceEnd
        let delta = max(minDelta, min(proposedTime - clip.timelineEnd, maxDelta))
        clips[index].sourceEnd = clip.sourceEnd + delta
        clips[index].fadeOutDuration = min(clips[index].fadeOutDuration, clips[index].sourceDuration / 2)
        draftClips = clips
    }

    /// Removes a clip, closing the gap by default ("cut" not "mute"); `closeGap: false` (Option-Delete) leaves a silent gap.
    private func deleteClip(id: UUID, closeGap: Bool = true) {
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let removed = clips[index]
        recordArrangementUndo()
        clips.remove(at: index)
        if closeGap {
            for otherIndex in clips.indices where clips[otherIndex].lane == removed.lane
                && clips[otherIndex].timelineStart >= removed.timelineEnd {
                clips[otherIndex].timelineStart -= removed.sourceDuration
            }
        }
        draftClips = clips
        if selectedClipID == id { selectedClipID = nil }
        applyArrangement()
    }

    private func setFade(forClip id: UUID, fadeIn: Double? = nil, fadeOut: Double? = nil) {
        var clips = draftClips.isEmpty ? [singleImplicitClip] : draftClips
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        if let fadeIn {
            clips[index].fadeInDuration = max(0, min(fadeIn, clips[index].sourceDuration / 2))
        }
        if let fadeOut {
            clips[index].fadeOutDuration = max(0, min(fadeOut, clips[index].sourceDuration / 2))
        }
        draftClips = clips
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

    // MARK: Arrangement (blade / two lanes), integrated into the main waveform

    // MARK: Transport

    private func togglePlayback() {
        if isPlayingThisTrack {
            player.togglePlayPause()
        } else {
            startPlayback(from: playheadTime)
            TutorialManager.shared.reportAction(.editorPlayed)
        }
    }

    private func auditionIntro() {
        startPlayback(from: draftStart)
    }

    private func auditionOutro() {
        let leadIn = max(6, draftFadeOut + 3)
        startPlayback(from: max(draftStart, stopTime - leadIn))
    }

    /// Commits first so the audition is honest, since the engine reads the stored trim/fades, not an unapplied draft.
    private func startPlayback(from absolute: Double) {
        apply()

        guard canPlay, let index = player.tracks.firstIndex(where: { $0.id == trackID }) else { return }
        let track = player.tracks[index]
        let relative = max(0, (absolute - track.startTime) / track.speedMultiplier)

        // Checks loaded audio, not just index, since the item may hold a stale file; cues without autoplay so it can be repositioned first.
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
        player.seek(to: max(0, (bounded - live.startTime) / live.speedMultiplier))
    }

    // MARK: Keyboard

    /// Scrolls the waveform in time, but only while the pointer is over it, since the surrounding sheet has its own ScrollView.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let hostWindow, event.window === hostWindow, isHoveringWaveform else { return event }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Falls back to deltaY for wheel mice, since a trackpad reports horizontal scroll in deltaX but a wheel has no deltaX.
            let horizontal = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard horizontal != 0 else { return nil }

            // Pixel-precise devices report points; a notched wheel reports lines.
            let points = event.hasPreciseScrollingDeltas ? horizontal : horizontal * 16

            if modifiers.contains(.command) || modifiers.contains(.option) {
                zoom(toVisible: visibleDuration * (1 - Double(points) / 300),
                     anchorTime: zoomAnchorTime)
                return nil
            }

            guard waveformWidth > 0 else { return nil }
            setViewStart(viewStart - Double(points / waveformWidth) * visibleDuration)
            return nil
        }
    }

    /// SwiftUI's own shortcuts are unreliable in a self-presented sheet, and zoom keys must beat the booth's spacebar handler.
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
                    if !arrangementUndoStack.isEmpty { undoArrangement() } else { undoDraft() }
                    return nil
                case "y":
                    if !arrangementRedoStack.isEmpty { redoArrangement() } else { redoDraft() }
                    return nil
                default:
                    return event
                }
            }

            if modifiers.isEmpty, event.keyCode == 49 { // spacebar
                togglePlayback()
                return nil
            }

            // Option alone is allowed (it asks for a silent gap instead of closing it); any other modifier means "not a delete".
            if modifiers.subtracting(.option).isEmpty,
               (event.keyCode == 51 || event.keyCode == 117), // delete / forward delete
               let selectedClipID {
                deleteClip(id: selectedClipID, closeGap: !modifiers.contains(.option))
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
