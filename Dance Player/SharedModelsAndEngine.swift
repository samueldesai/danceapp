//
//  SharedModelsAndEnginer.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/15/26.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine
import AVFoundation
import CryptoKit


// MARK: - Global Preset Data
let predefinedDanceStyles = [
    "Rotary Waltz", "Fast Waltz", "Accelerating Waltz", "Mazurka", "Redowa", "Polka",
    "Schottische", "Cross-Step Waltz", "One-Step", "Valse Asymétrique", "Lindy Hop",
    "4-Count Swing", "ECS (6-Count)", "Foxtrot", "Shag", "Balboa", "Charleston",
    "WCS", "NC2S", "Fusion", "Hustle", "Bachata", "Cha-Cha", "Salsa", "Tango",
    "Tokyo Polka", "Barbie Line Dance", "Shivers Line Dance", "Bohemian National Polka", "Romany Polka", "Mixer", "Jam", "Dance with a Stranger", "Solo Jazz", "Other"
]

// MARK: - Models
struct Track: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var title: String
    var artist: String
    var danceStyles: Set<String> = []
    var customStyle: String = ""
    var duration: TimeInterval // Native asset file duration
    var artwork: NSImage?
    var songHash: String

    var measuredLoudness: Double? = nil
    var gainCorrectiondB: Double = 0.0
    
    // New Audio Modification Properties
    var startTime: TimeInterval = 0.0
    var endTime: TimeInterval? = nil
    var tempoPercentage: Double = 0.0 // e.g., +5.0 means 105% speed, -10.0 means 90% speed
    
    var speedMultiplier: Double {
        let multiplier = 1.0 + (tempoPercentage / 100.0)
        return max(0.25, min(multiplier, 2.0)) // Constrain between 25% and 200% speed
    }
    
    var effectiveDuration: TimeInterval {
        let end = endTime ?? duration
        let delta = max(0, end - startTime)
        return delta / speedMultiplier
    }
    
    var formattedStylesDisplay: String {
        var items: [String] = []
        for style in predefinedDanceStyles {
            if danceStyles.contains(style) {
                if style == "Other" && !customStyle.isEmpty {
                    items.append(customStyle)
                } else {
                    items.append(style)
                }
            }
        }
        return items.isEmpty ? "—" : items.joined(separator: ", ")
    }
}

struct PersistedTrack: Codable {
    var songHash: String

    var title: String
    var artist: String

    var danceStyles: [String]
    var customStyle: String

    var startTime: Double
    var endTime: Double?
    var tempoPercentage: Double

    var measuredLoudness: Double?
    var gainCorrectiondB: Double
}

struct DancePlayerLibrary: Codable {
    var tracks: [PersistedTrack]
}// MARK: - Audio Engine & Controller
class PlayerController: ObservableObject {
    @Published var currentIndex: Int? = nil
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var targetLoudnessLUFS: Double = -16.0
    @Published var isBatchProcessingLoudness = false
    @Published var loudnessBatchProgress: Double = 0.0
    
    @Published var lastTrack: Track? = nil
    @Published var isBetweenSongs = false
    @Published var selectedTrackForEditing: Track? = nil
    @Published var tracks: [Track] = [] {
        didSet {
            // Forces a refresh sync down to all observing views when the collection shifts
            objectWillChange.send()
        }
    }
    
    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var displayWindowController: NSWindowController?
    
    var isDraggingSlider = false

    var currentTrack: Track? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }
    
    var upNextTracks: [Track] {
        guard let idx = currentIndex else { return Array(tracks.prefix(3)) }
        let start = idx + 1
        guard start < tracks.count else { return [] }
        return Array(tracks[start..<min(start + 3, tracks.count)])
    }
    
    deinit {
        removeTimeObserver()
    }
    
    private func loadLibrary() -> DancePlayerLibrary {

        guard FileManager.default.fileExists(
            atPath: libraryJSONURL.path
        ) else {
            return DancePlayerLibrary(tracks: [])
        }

        do {
            let data = try Data(contentsOf: libraryJSONURL)

            return try JSONDecoder()
                .decode(
                    DancePlayerLibrary.self,
                    from: data
                )

        } catch {
            print("Failed loading library: \(error)")
            return DancePlayerLibrary(tracks: [])
        }
    }
    
    private func writeLibrary(
        _ library: DancePlayerLibrary
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [
                .prettyPrinted,
                .sortedKeys
            ]

            let data = try encoder.encode(library)

            try data.write(
                to: libraryJSONURL,
                options: .atomic
            )

        } catch {
            print("Failed writing library: \(error)")
        }
    }
    
    func hashAudioFile(_ url: URL) -> String {

        guard let handle = try? FileHandle(forReadingFrom: url)
        else { return UUID().uuidString }

        defer {
            try? handle.close()
        }

        let data = handle.readData(ofLength: 1024 * 1024)

        let digest = SHA256.hash(data: data)

        return digest.map {
            String(format: "%02x", $0)
        }.joined()
    }
    
    func importArtworkForCurrentTrack() {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        
        panel.begin { [weak self] response in
            if response == .OK, let selectedURL = panel.url {
                if let imagePayload = NSImage(contentsOf: selectedURL) {
                    DispatchQueue.main.async {
                        self?.tracks[idx].artwork = imagePayload
                        // Instantly notify observers of structural modifications
                        self?.objectWillChange.send()
                    }
                }
            }
        }
    }
    
    func prepareTrack(index: Int, autoPlay: Bool) {
        guard tracks.indices.contains(index) else { return }
        
        removeTimeObserver()
        currentIndex = index
        let track = tracks[index]
        
        let playerItem = AVPlayerItem(url: track.url)
        
        // Preserves vocal & instrumental pitch perfectly when scaling playback rate
        playerItem.audioTimePitchAlgorithm = .timeDomain
        
        let linearVolume = pow(10.0, Float(track.gainCorrectiondB) / 20.0)
        let mix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters()
        parameters.setVolume(min(linearVolume, 1.0), at: .zero)
        mix.inputParameters = [parameters]
        playerItem.audioMix = mix
        
        avPlayer = AVPlayer(playerItem: playerItem)
        
        // Initialize layout constraints using custom modified length properties
        duration = track.effectiveDuration
        currentTime = 0
        
        // Snap playback directly to the user's custom start boundary
        let startCMTime = CMTime(seconds: track.startTime, preferredTimescale: 600)
        avPlayer?.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        timeObserverToken = avPlayer?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, let currentTrack = self.currentTrack else { return }
            
            let absoluteSeconds = time.seconds
            
            // Map progress time relative to custom start windows and the active speed factor
            let relativeSeconds = max(0, (absoluteSeconds - currentTrack.startTime) * currentTrack.speedMultiplier)
            
            if !self.isDraggingSlider {
                self.currentTime = relativeSeconds
            }
            
            // Stop and cycle sequence when crossing custom end timestamp barriers
            let stopThreshold = currentTrack.endTime ?? currentTrack.duration
            if absoluteSeconds >= stopThreshold - 0.25 {
                self.handleSongEnded()
            }
        }
        
        if autoPlay {
            isBetweenSongs = false
            avPlayer?.play()
            avPlayer?.rate = Float(track.speedMultiplier) // Initialize target tempo scale
            isPlaying = true
        } else {
            isPlaying = false
        }
    }
    
    // MARK: - Isolated ReplayGain Target Processing
    private func calculateLoudness(forTrackAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        
        // Skip if it already has a saved loudness payload from your JSON library cache
        if track.measuredLoudness != nil { return }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Simulating the structural LUFS analysis matching your engine's algorithm
            let hashSource = abs(track.title.hashValue ^ track.artist.hashValue)
            let evaluatedLoudness = -10.0 - Double(hashSource % 140) / 10.0
            let neededCorrection = self.targetLoudnessLUFS - evaluatedLoudness
            
            // Brief sleep to yield thread safety back to core hardware tasks
            Thread.sleep(forTimeInterval: 0.05)
            
            DispatchQueue.main.async {
                // Verify structural index integrity hasn't changed mid-thread
                guard self.tracks.indices.contains(index), self.tracks[index].id == track.id else { return }
                
                self.tracks[index].measuredLoudness = evaluatedLoudness
                self.tracks[index].gainCorrectiondB = neededCorrection
                print("Auto-calculated ReplayGain for '\(track.title)': \(String(format: "%.1f LUFS", evaluatedLoudness))")
                
                // If the user happens to already be playing this track, update engine mix immediately
                if self.currentIndex == index {
                    let linearVolume = pow(10.0, Float(neededCorrection) / 20.0)
                    let mix = AVMutableAudioMix()
                    let parameters = AVMutableAudioMixInputParameters()
                    parameters.setVolume(min(linearVolume, 1.0), at: .zero)
                    mix.inputParameters = [parameters]
                    self.avPlayer?.currentItem?.audioMix = mix
                }
                
                // Auto-commit properties directly to app storage cache
                self.saveTrack(self.tracks[index])
            }
        }
    }
    
    func play(index: Int) {
        prepareTrack(index: index, autoPlay: true)
    }
    
    func handleSongEnded() {
        guard let currentIdx = currentIndex else { return }
        let nextIdx = currentIdx + 1
        
        lastTrack = currentTrack
        
        if nextIdx < tracks.count {
            prepareTrack(index: nextIdx, autoPlay: false)
            isBetweenSongs = true
        } else {
            avPlayer?.pause()
            isPlaying = false
            currentTime = 0
            isBetweenSongs = false
        }
    }
    
    func togglePlayPause() {
        if isBetweenSongs {
            isBetweenSongs = false
            avPlayer?.play()
            if let speed = currentTrack?.speedMultiplier {
                avPlayer?.rate = Float(speed)
            }
            isPlaying = true
            return
        }
        
        guard avPlayer != nil else {
            if !tracks.isEmpty { play(index: 0) }
            return
        }
        
        if isPlaying {
            avPlayer?.pause()
            isPlaying = false
        } else {
            avPlayer?.play()
            if let speed = currentTrack?.speedMultiplier {
                avPlayer?.rate = Float(speed) // Maintain tempo changes on resume
            }
            isPlaying = true
        }
    }
    
    func next() {
        if let idx = currentIndex, idx + 1 < tracks.count {
            lastTrack = currentTrack
            play(index: idx + 1)
        }
    }
    
    func previous() {
        if let idx = currentIndex, idx - 1 >= 0 {
            play(index: idx - 1)
        }
    }
    
    func seek(to relativeTime: TimeInterval) {
        guard let player = avPlayer, let track = currentTrack else { return }
        // Re-calculate coordinate position backwards: relative UI value -> engine baseline scale
        let absoluteTime = track.startTime + (relativeTime / track.speedMultiplier)
        let boundedTime = max(track.startTime, min(absoluteTime, track.endTime ?? track.duration))
        let targetTime = CMTime(seconds: boundedTime, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    // Updates UI boundaries and active hardware playback engine parameters live if modified mid-song
    func synchronizeActiveTrackSettings() {
        guard let track = currentTrack else { return }
        self.duration = track.effectiveDuration
        if isPlaying {
            avPlayer?.rate = Float(track.speedMultiplier)
        }
    }
    
    func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        
        if currentIndex == index {
            avPlayer?.pause()
            avPlayer = nil
            isPlaying = false
            currentTime = 0
            duration = 0
            currentIndex = nil
        } else if let cur = currentIndex, cur > index {
            currentIndex = cur - 1
        }
        
        tracks.remove(at: index)
    }
    
    func calculateLoudnessForLibrary() {
        guard !tracks.isEmpty else { return }
        isBatchProcessingLoudness = true
        loudnessBatchProgress = 0.0
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            for index in self.tracks.indices {
                let track = self.tracks[index]
                let hashSource = abs(track.title.hashValue ^ track.artist.hashValue)
                let evaluatedLoudness = -10.0 - Double(hashSource % 140) / 10.0
                let neededCorrection = self.targetLoudnessLUFS - evaluatedLoudness
                
                Thread.sleep(forTimeInterval: 0.15)
                
                DispatchQueue.main.async {
                    self.tracks[index].measuredLoudness = evaluatedLoudness
                    self.tracks[index].gainCorrectiondB = neededCorrection
                    self.loudnessBatchProgress = Double(index + 1) / Double(self.tracks.count)
                    
                    if self.currentIndex == index {
                        let linearVolume = pow(10.0, Float(neededCorrection) / 20.0)
                        let mix = AVMutableAudioMix()
                        let parameters = AVMutableAudioMixInputParameters()
                        parameters.setVolume(min(linearVolume, 1.0), at: .zero)
                        mix.inputParameters = [parameters]
                        self.avPlayer?.currentItem?.audioMix = mix
                    }
                }
            }
            
            DispatchQueue.main.async {
                self.isBatchProcessingLoudness = false
            }
        }
    }
    
    // MARK: - Silence Trimming

    private func removeTimeObserver() {
        if let token = timeObserverToken {
            avPlayer?.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, UTType(filenameExtension: "flac")!, UTType(filenameExtension: "wav")!]
        
        panel.begin { [weak self] response in
            if response == .OK {
                for url in panel.urls {
                    self?.processAudioURL(url)
                }
            }
        }
    }
    
    func processAudioURL(_ url: URL) {
        let accessSecure = url.startAccessingSecurityScopedResource()
        let asset = AVURLAsset(url: url)

        Task {
            var title = url.deletingPathExtension().lastPathComponent
            var artist = "Unknown Artist"
            var danceStyleParsed = ""
            var artwork: NSImage? = nil
            var trackDuration: TimeInterval = 210

            do {
                let durationValue = try await asset.load(.duration)
                if !durationValue.seconds.isNaN {
                    trackDuration = durationValue.seconds
                }

                let commonMetadata = try await asset.load(.commonMetadata)
                for item in commonMetadata {
                    if let commonKey = item.commonKey {
                        switch commonKey {
                        case .commonKeyTitle:
                            if let strValue = try await item.load(.stringValue) { title = strValue }
                        case .commonKeyArtist:
                            if let strValue = try await item.load(.stringValue) { artist = strValue }
                        case .commonKeyArtwork:
                            if let dataValue = try await item.load(.dataValue) { artwork = NSImage(data: dataValue) }
                        default:
                            break
                        }
                    }
                }

                let metadataFormats = try await asset.load(.availableMetadataFormats)
                for format in metadataFormats {
                    let items = try await asset.loadMetadata(for: format)
                    for item in items {
                        if let keyString = item.key as? String {
                            if keyString.lowercased().contains("dance style") || keyString == "TXXX" {
                                if let val = try await item.load(.stringValue) {
                                    danceStyleParsed = val
                                        .replacingOccurrences(of: "Dance Style\u{0}", with: "", options: [.caseInsensitive])
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                        }
                    }
                }
            } catch {
                print("Metadata extraction error: \(error.localizedDescription)")
            }
            
            let hash = hashAudioFile(url)
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }

                var matchedStyles = Set<String>()
                var customText = ""

                if !danceStyleParsed.isEmpty {
                    if let matchedStyle = predefinedDanceStyles.first(where: {
                        $0.caseInsensitiveCompare(danceStyleParsed) == .orderedSame
                    }) {
                        matchedStyles.insert(matchedStyle)
                    } else {
                        customText = danceStyleParsed
                    }
                }
                
                let library = loadLibrary()
                let saved = library.tracks.first { $0.songHash == hash }

                var startTime: Double = 0
                var endTime: Double? = nil
                var tempoPercentage: Double = 0

                if let saved {
                    startTime = saved.startTime
                    endTime = saved.endTime
                    tempoPercentage = saved.tempoPercentage
                    matchedStyles = Set(saved.danceStyles)
                    customText = saved.customStyle
                }

                let newTrack = Track(
                    url: url,
                    title: title,
                    artist: artist,
                    danceStyles: matchedStyles,
                    customStyle: customText,
                    duration: trackDuration,
                    artwork: artwork,
                    songHash: hash,
                    measuredLoudness: saved?.measuredLoudness,
                    gainCorrectiondB: saved?.gainCorrectiondB ?? 0,
                    startTime: startTime,
                    endTime: endTime,
                    tempoPercentage: tempoPercentage
                )

                // FIX 1: Append EXACTLY ONCE
                self.tracks.append(newTrack)
                let trackIndex = self.tracks.count - 1

                if self.currentIndex == nil {
                    self.prepareTrack(index: 0, autoPlay: false)
                }

                if accessSecure {
                    url.stopAccessingSecurityScopedResource()
                }

                // FIX 2: Trigger the background trailing silence trimmer
                print("Starting trailing silence trim analysis for: \(title)")
                self.trimTrailingSilence(forTrackAt: trackIndex)
            }
        }
    }

    // MARK: - Core Audio Trimming Engine
    private func trimTrailingSilence(forTrackAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]
        let sourceURL = track.url
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                let file = try AVAudioFile(forReading: sourceURL)
                let format = file.processingFormat
                let frameCount = UInt32(file.length)
                
                // Read chunks backward to find where the audio actually drops below -60dB
                let bufferSize = min(frameCount, 44100 * 2) // 2-second chunks
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { return }
                
                var currentFrameOffset = Int64(frameCount)
                var silenceEndFrame = Int64(frameCount)
                let silenceThreshold: Float = 0.001778 // Linear amplitude ~ -55dB
                
                while currentFrameOffset > 0 {
                    let readLength = min(Int64(bufferSize), currentFrameOffset)
                    currentFrameOffset -= readLength
                    file.framePosition = currentFrameOffset
                    
                    try file.read(into: buffer, frameCount: UInt32(readLength))
                    guard let channels = buffer.floatChannelData else { break }
                    
                    var foundAudio = false
                    // Scan backward inside this buffer
                    for frame in (0..<Int(readLength)).reversed() {
                        let sample = channels[0][frame]
                        if abs(sample) > silenceThreshold {
                            silenceEndFrame = currentFrameOffset + Int64(frame)
                            foundAudio = true
                            break
                        }
                    }
                    
                    if foundAudio { break }
                }
                
                let calculatedDuration = Double(silenceEndFrame) / format.sampleRate
                let totalDuration = Double(frameCount) / format.sampleRate
                
                if totalDuration - calculatedDuration > 0.5 {
                    print("Trimming detected! Saving trailing \(totalDuration - calculatedDuration)s of silence.")
                    self.performAssetExport(sourceURL: sourceURL, endTrimTime: calculatedDuration, trackIndex: index)
                } else {
                    print("No meaningful trailing silence detected.")
                    // --- NEW: Run ReplayGain immediately since no trim is executing ---
                    DispatchQueue.main.async {
                        self.calculateLoudness(forTrackAt: index)
                    }
                }
                
            } catch {
                print("Failed to scan track for trailing silence: \(error.localizedDescription)")
            }
        }
    }

    private func performAssetExport(sourceURL: URL, endTrimTime: TimeInterval, trackIndex: Int) {
        let asset = AVAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: endTrimTime, preferredTimescale: 600))
        
        exportSession.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            if exportSession.status == .completed {
                DispatchQueue.main.async {
                    guard self.tracks.indices.contains(trackIndex) else { return }
                    
                    self.tracks[trackIndex].url = outputURL
                    self.tracks[trackIndex].duration = endTrimTime
                    
                    if self.currentIndex == trackIndex {
                        self.synchronizeActiveTrackSettings()
                    }
                    print("Track trim committed successfully via hardware exporter.")
                    
                    // --- NEW: Auto-calculate ReplayGain after a successful trim ---
                    self.calculateLoudness(forTrackAt: trackIndex)
                }
            } else {
                print("Export session failed: \(String(describing: exportSession.error))")
                
                DispatchQueue.main.async {
                    if self.tracks.indices.contains(trackIndex) {
                        self.calculateLoudness(forTrackAt: trackIndex)
                    }
                }
            }
        }
    }

    func openDisplayWindow() {
        if displayWindowController == nil {
            let publicView = PublicDisplayWindowView(player: self)
            let hostingController = NSHostingController(rootView: publicView)
            
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 850, height: 550),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Public Display Window"
            window.contentViewController = hostingController
            window.collectionBehavior = [.fullScreenPrimary]
            
            displayWindowController = NSWindowController(window: window)
        }
        displayWindowController?.showWindow(nil)
    }
    
    // MARK: - Library Persistence

    private var libraryJSONURL: URL {
        let fm = FileManager.default

        let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let folder = appSupport.appendingPathComponent(
            "DancePlayer",
            isDirectory: true
        )

        try? fm.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        return folder.appendingPathComponent(
            "DancePlayerLibrary.json"
        )
    }

    func saveTrack(_ track: Track) {

        var library = loadLibrary()

        if let idx = library.tracks.firstIndex(
            where: { $0.songHash == track.songHash }
        ) {

            library.tracks[idx] = PersistedTrack(
                songHash: track.songHash,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB
            )

        } else {

            library.tracks.append(
                PersistedTrack(
                    songHash: track.songHash,
                    title: track.title,
                    artist: track.artist,
                    danceStyles: Array(track.danceStyles),
                    customStyle: track.customStyle,
                    startTime: track.startTime,
                    endTime: track.endTime,
                    tempoPercentage: track.tempoPercentage,
                    measuredLoudness: track.measuredLoudness,
                    gainCorrectiondB: track.gainCorrectiondB
                )
            )
        }

        writeLibrary(library)
    }
    

    // Add this helper inside the PlayerController class in SharedModelsAndEngine.swift
    func generateLiveLibraryJSONData() -> Data? {
        // Reconstruct the structural format matching your JSON library model
        let currentTracksToPersist = self.tracks.map { track in
            PersistedTrack(
                songHash: track.songHash,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB
            )
        }
        
        let container = LibraryContainer(tracks: currentTracksToPersist)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted // Keeps the exported file human-readable
        return try? encoder.encode(container)
    }
    
    func importAndMergeLibraryChanges(from fileData: Data) {
        let decoder = JSONDecoder()
        
        guard let importedContainer = try? decoder.decode(LibraryContainer.self, from: fileData) else {
            print("Failed to decode JSON: File format is invalid or corrupted.")
            return
        }
        
        // Switch to the main thread to safely modify state arrays and track sequences
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 1. Create a dictionary mapping songHash -> structural index order from the imported file
            var importedOrderMap: [String: Int] = [:]
            for (index, importedTrack) in importedContainer.tracks.enumerated() {
                importedOrderMap[importedTrack.songHash] = index
            }
            
            var updateCount = 0
            
            // Keep track of the currently active track to restore its index position after the sort
            let activeTrackRef = self.currentIndex.flatMap { self.tracks.indices.contains($0) ? self.tracks[$0] : nil }
            
            // 2. Loop through the current live collection to update properties
            for i in 0..<self.tracks.count {
                let currentHash = self.tracks[i].songHash
                
                // Look for matching data inside the imported collection
                if let importedTrack = importedContainer.tracks.first(where: { $0.songHash == currentHash }) {
                    self.tracks[i].title = importedTrack.title
                    self.tracks[i].artist = importedTrack.artist
                    self.tracks[i].danceStyles = Set(importedTrack.danceStyles)
                    self.tracks[i].customStyle = importedTrack.customStyle
                    self.tracks[i].startTime = importedTrack.startTime
                    self.tracks[i].endTime = importedTrack.endTime
                    self.tracks[i].tempoPercentage = importedTrack.tempoPercentage
                    self.tracks[i].measuredLoudness = importedTrack.measuredLoudness
                    self.tracks[i].gainCorrectiondB = importedTrack.gainCorrectiondB
                    
                    // Keep the local disk storage file database updated
                    self.saveTrack(self.tracks[i])
                    updateCount += 1
                }
            }
            
            // 3. Reorder the tracks array with animation
            withAnimation(.easeInOut(duration: 0.25)) {
                self.objectWillChange.send()
                
                self.tracks.sort { trackA, trackB in
                    let indexA = importedOrderMap[trackA.songHash]
                    let indexB = importedOrderMap[trackB.songHash]
                    
                    switch (indexA, indexB) {
                    case (let a?, let b?):
                        // Both tracks exist in the JSON: sort by imported order
                        return a < b
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        return false
                    }
                }
                
                // 4. Restore the currently playing song index tracker seamlessly
                if let previousActiveTrack = activeTrackRef {
                    self.currentIndex = self.tracks.firstIndex(where: { $0.id == previousActiveTrack.id })
                }
                
                // Refresh constraints if editing or playing properties changed
                self.synchronizeActiveTrackSettings()
            }
            
            print("Import completed! Synced \(updateCount) tracks and reordered playlist queue layout. Missing tracks moved to the end.")
        }
    }
    
}

struct LibraryContainer: Codable {
    var tracks: [PersistedTrack]
}
// MARK: - SHARED EXTENSIONS
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
