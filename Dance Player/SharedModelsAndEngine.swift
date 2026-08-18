//  SharedModelsAndEngine.swift

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Combine
import AVFoundation
import CryptoKit
import Accelerate
import Network
import Security
import MediaPlayer

enum HapticFeedback {
    static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}


// MARK: - Global Preset Data
let predefinedDanceStyles = [
    "Cross-Step Waltz", "Rotary Waltz", "Fast Waltz", "Lindy Hop", "West Coast Swing", "Fusion", "Polka", "Accelerating Waltz", "4-Count Swing", "Night Club Two Step", "Bachata", "Cha-Cha", "Salsa", "Tango", "Tokyo Polka", "Barbie Line Dance", "Shivers Line Dance", "Bohemian National Polka", "Romany Polka", "Dawn Mazurka", "Cross-Step Waltz Mixer", "'T Smidje Mixer", "Jam", "Dance with a Stranger", "Last West Coast Swing", "Last Lindy Hop", "Last Cross-Step Waltz", "Last Rotary Waltz", "Other",
]

// MARK: - Models
enum TrackSource: String, Codable {
    case local
    case spotify
}

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
    var source: TrackSource = .local
    var isSkipped: Bool = false
    var spotifyURI: String? = nil
    var spotifyExternalURL: URL? = nil

    /// True once the DJ picks their own cover art. Artwork that merely came from the audio
    /// file's own tags is re-read on import instead of being stored in the project.
    var hasCustomArtwork: Bool = false

    var measuredLoudness: Double? = nil
    var gainCorrectiondB: Double = 0.0
    // Bumped when the analysis algorithm changes, so values cached by an older
    // (less accurate) version get re-measured instead of trusted forever.
    var loudnessAnalysisVersion: Int = 0

    // New Audio Modification Properties
    var startTime: TimeInterval = 0.0
    var endTime: TimeInterval? = nil
    var tempoPercentage: Double = 0.0 // e.g., +5.0 means 105% speed, -10.0 means 90% speed

    /// Zero is a hard cut; fades are measured in the file's own seconds so they keep musical length when tempo changes.
    var fadeInDuration: TimeInterval = 0.0
    var fadeOutDuration: TimeInterval = 0.0

    // Manually-entered BPM for the audience screen, independent of tempoPercentage (playback speed).
    var manualBPM: String = ""

    var speedMultiplier: Double {
        let multiplier = 1.0 + (tempoPercentage / 100.0)
        return max(0.25, min(multiplier, 2.0)) // Constrain between 25% and 200% speed
    }

    var effectiveDuration: TimeInterval {
        let end = endTime ?? duration
        let delta = max(0, end - startTime)
        return delta / speedMultiplier
    }

    /// The end timestamp with no fallback logic — the point the DJ set, or the file's own end.
    var resolvedEndTime: TimeInterval {
        endTime ?? duration
    }

    /// Playback hands over slightly before the end so a fade finishes before the time observer can overshoot it.
    static let endStopLead: TimeInterval = 0.25

    var playbackStopTime: TimeInterval {
        max(startTime, resolvedEndTime - Track.endStopLead)
    }

    /// The stretch of audio actually heard, in file seconds.
    var playableRegionDuration: TimeInterval {
        max(0, playbackStopTime - startTime)
    }

    /// Fades are scaled down together, preserving their ratio, when trimming shrinks the region below their combined length.
    private var clampedFades: (fadeIn: TimeInterval, fadeOut: TimeInterval) {
        let region = playableRegionDuration
        let requestedIn = max(0, fadeInDuration)
        let requestedOut = max(0, fadeOutDuration)
        let total = requestedIn + requestedOut
        guard region > 0, total > 0 else { return (0, 0) }
        guard total > region else { return (requestedIn, requestedOut) }

        let scale = region / total
        return (requestedIn * scale, requestedOut * scale)
    }

    var effectiveFadeInDuration: TimeInterval { clampedFades.fadeIn }
    var effectiveFadeOutDuration: TimeInterval { clampedFades.fadeOut }
    var hasFades: Bool { effectiveFadeInDuration > 0 || effectiveFadeOutDuration > 0 }
    
    /// Includes the definite article so "Last …" dances announce as "the Last Rotary Waltz".
    var formattedStylesDisplay: String {
        stylesDisplay(includingJam: true)
    }

    private func stylesDisplay(includingJam: Bool) -> String {
        let isJam = includingJam && danceStyles.contains("Jam")
        let isWithStranger = danceStyles.contains("Dance with a Stranger")
        // "Cross-Step Waltz Mixer" already implies Cross-Step Waltz — listing both reads
        // as "Cross-Step Waltz or Cross-Step Waltz Mixer" instead of just the specific one.
        let hasCrossStepWaltzMixer = danceStyles.contains("Cross-Step Waltz Mixer")

        var items: [String] = []
        for style in predefinedDanceStyles {
            guard style != "Jam", style != "Dance with a Stranger" else { continue }
            guard !(style == "Cross-Step Waltz" && hasCrossStepWaltzMixer) else { continue }
            guard danceStyles.contains(style) else { continue }

            if style == "Other", !customStyle.isEmpty {
                items.append(customStyle)
            } else {
                items.append(style)
            }
        }

        var result = items.joined(separator: " or ")

        if isWithStranger {
            result = result.isEmpty ? "Dance with a Stranger" : "\(result) with a Stranger"
        }

        if isJam {
            result = result.isEmpty ? "Jam" : "Jam (\(result))"
        }

        return result.isEmpty ? "—" : result
    }

    var isJam: Bool { danceStyles.contains("Jam") }
    var isWithStranger: Bool { danceStyles.contains("Dance with a Stranger") }

    /// These dances change tempo by design, so a single BPM figure would misrepresent them.
    var hasVariableTempo: Bool {
        !danceStyles.isDisjoint(with: ["Accelerating Waltz", "Romany Polka"])
    }

    /// Mixers need teaching time on the floor, so the set clock budgets for them. Covers the
    /// two named mixers plus anything the DJ filed under "Other" and called a mixer.
    var countsAsMixer: Bool {
        if !danceStyles.isDisjoint(with: ["Cross-Step Waltz Mixer", "'T Smidje Mixer"]) {
            return true
        }
        return danceStyles.contains("Other") && customStyle.lowercased().contains("mixer")
    }

    /// The dance on its own, with the Jam framing dropped — the jam announcement supplies its
    /// own wording, so "Jam (Cross-Step Waltz)" would read twice.
    var audienceDanceOnlyDisplay: String {
        var text = stylesDisplay(includingJam: false)
        for (full, short) in Track.audienceStyleAbbreviations {
            text = text.replacingOccurrences(of: full, with: short)
        }
        return text
    }

    /// Shortened for the floor only — the booth keeps the full name so the style picker and
    /// guideline report stay searchable.
    private static let audienceStyleAbbreviations = ["Night Club Two Step": "NC2S"]

    var audienceStylesDisplay: String {
        var text = formattedStylesDisplay
        for (full, short) in Track.audienceStyleAbbreviations {
            text = text.replacingOccurrences(of: full, with: short)
        }
        return text
    }

    /// These are specific named mixes rather than general dance styles, so they announce as
    /// "the next song is the Romany Polka" — "a Romany Polka" reads as one of many.
    private static let stylesTakingDefiniteArticle: Set<String> = [
        "Bohemian National Polka",
        "Barbie Line Dance",
        "Romany Polka",
        "'T Smidje Mixer",
        "Dawn Mazurka",
    ]

    var nextSongLeadIn: String {
        let display = formattedStylesDisplay
        // A set has exactly one last rotary waltz, so it takes "the" for the same reason the
        // named choreographies do — "a Last Rotary Waltz" isn't English.
        let takesDefiniteArticle = Track.stylesTakingDefiniteArticle.contains(display)
            || display.hasPrefix("Last ")

        return takesDefiniteArticle
            ? "The next song is the"
            : "The next song is a"
    }
}

struct PersistedTrack: Codable {
    var songHash: String
    var source: TrackSource?
    var isSkipped: Bool?
    var spotifyURI: String?
    var spotifyExternalURL: String?

    var title: String
    var artist: String

    var danceStyles: [String]
    var customStyle: String

    var startTime: Double
    var endTime: Double?
    var tempoPercentage: Double
    var manualBPM: String? = nil
    /// Absent in projects written before 1.3, which is read as "no fade".
    var fadeInDuration: Double? = nil
    var fadeOutDuration: Double? = nil

    var measuredLoudness: Double?
    var gainCorrectiondB: Double
    var loudnessAnalysisVersion: Int? = nil
    var hasCustomArtwork: Bool? = nil
    var artworkData: Data? = nil
}

struct DancePlayerLibrary: Codable {
    var tracks: [PersistedTrack]
}

struct ProjectPackageExport: Codable {
    var version: Int = 1
    var projectName: String
    var tracks: [ProjectPackageTrack]
    // Advanced Settings are project-specific — each new project starts with these off,
    // regardless of what a previously-opened project had set.
    var showTempo: Bool = false
    var autoplayEnabled: Bool = false
    var autoplayDelaySeconds: Double = 10.0

    private enum CodingKeys: String, CodingKey {
        case version
        case projectName
        case tracks
        case showTempo
        case autoplayEnabled
        case autoplayDelaySeconds
    }

    init(
        projectName: String,
        tracks: [ProjectPackageTrack],
        version: Int = 1,
        showTempo: Bool = false,
        autoplayEnabled: Bool = false,
        autoplayDelaySeconds: Double = 10.0
    ) {
        self.version = version
        self.projectName = projectName
        self.tracks = tracks
        self.showTempo = showTempo
        self.autoplayEnabled = autoplayEnabled
        self.autoplayDelaySeconds = autoplayDelaySeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? "Dance Player Project"
        tracks = try container.decodeIfPresent([ProjectPackageTrack].self, forKey: .tracks) ?? []
        // Older project files predate these keys — default to disabled rather than
        // trying to carry over some prior global setting.
        showTempo = try container.decodeIfPresent(Bool.self, forKey: .showTempo) ?? false
        autoplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoplayEnabled) ?? false
        autoplayDelaySeconds = try container.decodeIfPresent(Double.self, forKey: .autoplayDelaySeconds) ?? 10.0
    }
}

struct ProjectPackageOrderExport: Codable {
    var version: Int = 1
    var songHashes: [String]

    private enum CodingKeys: String, CodingKey {
        case version
        case songHashes
    }

    init(songHashes: [String], version: Int = 1) {
        self.version = version
        self.songHashes = songHashes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        songHashes = try container.decodeIfPresent([String].self, forKey: .songHashes) ?? []
    }
}

extension NSImage {
    /// Actual pixels, not `size`, which is in points and lies about a high-DPI image.
    var pixelDimensions: (width: Int, height: Int)? {
        guard let rep = representations.first else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }
}

private extension NSImage {
    /// Stored at native resolution as JPEG, not PNG, keeping full-size cover art to a few hundred KB.
    var projectPackageData: Data? {
        guard let tiffData = tiffRepresentation,
              let source = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return source.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

private extension Track {

    /// Gated on hasCustomArtwork so DJ-downloaded art isn't silently overwritten by Spotify's lower-resolution version.
    var persistableArtworkData: Data? {
        guard hasCustomArtwork else { return nil }
        return artwork?.projectPackageData
    }
}

struct ProjectPackageTrack: Codable {
    var songHash: String
    var source: TrackSource
    var isSkipped: Bool?
    var spotifyURI: String?
    var spotifyExternalURL: String?
    var title: String
    var artist: String
    var danceStyles: [String]
    var customStyle: String
    var startTime: Double
    var endTime: Double?
    var tempoPercentage: Double
    var manualBPM: String? = nil
    var fadeInDuration: Double? = nil
    var fadeOutDuration: Double? = nil
    var measuredLoudness: Double?
    var gainCorrectiondB: Double
    var loudnessAnalysisVersion: Int? = nil
    var duration: Double
    var localFileName: String?
    /// Set instead of `localFileName` when the audio ships inside the app (a Popular Edit),
    /// so a project doesn't carry a second copy of a file every install already has.
    var bundledFileName: String?
    var hasCustomArtwork: Bool?
    var artworkFileName: String?
    var artworkData: Data?

    init(
        from track: Track,
        localFileName: String? = nil,
        bundledFileName: String? = nil,
        artworkFileName: String? = nil
    ) {
        self.songHash = track.songHash
        self.source = track.source
        self.isSkipped = track.isSkipped
        self.spotifyURI = track.spotifyURI
        self.spotifyExternalURL = track.spotifyExternalURL?.absoluteString
        self.title = track.title
        self.artist = track.artist
        self.danceStyles = Array(track.danceStyles)
        self.customStyle = track.customStyle
        self.startTime = track.startTime
        self.endTime = track.endTime
        self.tempoPercentage = track.tempoPercentage
        self.manualBPM = track.manualBPM
        self.fadeInDuration = track.fadeInDuration
        self.fadeOutDuration = track.fadeOutDuration
        self.measuredLoudness = track.measuredLoudness
        self.gainCorrectiondB = track.gainCorrectiondB
        self.loudnessAnalysisVersion = track.loudnessAnalysisVersion
        self.duration = track.duration
        self.localFileName = localFileName
        self.bundledFileName = bundledFileName
        self.hasCustomArtwork = track.hasCustomArtwork
        self.artworkFileName = track.source == .local ? artworkFileName : nil
        // No sidecar file (which the exporter only writes for local songs) means the art rides
        // inline instead — that's how a Spotify track's downloaded art gets kept.
        self.artworkData = artworkFileName == nil ? track.persistableArtworkData : nil
    }

    var persistedTrack: PersistedTrack {
        PersistedTrack(
            songHash: songHash,
            source: source,
            isSkipped: isSkipped,
            spotifyURI: spotifyURI,
            spotifyExternalURL: spotifyExternalURL,
            title: title,
            artist: artist,
            danceStyles: danceStyles,
            customStyle: customStyle,
            startTime: startTime,
            endTime: endTime,
            tempoPercentage: tempoPercentage,
            manualBPM: manualBPM,
            fadeInDuration: fadeInDuration,
            fadeOutDuration: fadeOutDuration,
            measuredLoudness: measuredLoudness,
            gainCorrectiondB: gainCorrectiondB,
            loudnessAnalysisVersion: loudnessAnalysisVersion,
            hasCustomArtwork: hasCustomArtwork,
            artworkData: artworkData
        )
    }

    var spotifyImportInput: String? {
        spotifyURI ?? (songHash.hasPrefix("spotify:") ? songHash : nil)
    }
}

struct TaggedStylesExport: Codable {
    var styles: [TaggedStyleExport]
}

struct TaggedStyleExport: Codable {
    var styleName: String
    var tracks: [PersistedTrack]
}

private struct TaggedStyleRegistry {
    private let styleBySongHash: [String: String]

    private static let taggedFolderName = "tagged_jsons"

    static let shared = TaggedStyleRegistry.load()

    private static func load() -> TaggedStyleRegistry {
        var styleBySongHash: [String: String] = [:]
        var loadedSourceCount = 0

        let jsonURLs = bundledTaggedJSONURLs()

        for url in jsonURLs {
            let resourceName = url.deletingPathExtension().lastPathComponent

            guard let data = try? Data(contentsOf: url),
                  let taggedStyles = try? JSONDecoder().decode(TaggedStylesExport.self, from: data)
            else {
                print("Skipped tagged style file: \(resourceName).json")
                continue
            }

            var trackCount = 0

            for styleGroup in taggedStyles.styles {
                let styleName = styleGroup.styleName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !styleName.isEmpty else { continue }

                for persistedTrack in styleGroup.tracks {
                    styleBySongHash[persistedTrack.songHash] = styleName
                    trackCount += 1
                }
            }

            loadedSourceCount += 1
            print("Loaded tagged style source '\(resourceName).json' with \(trackCount) hash entries across \(taggedStyles.styles.count) style section(s).")
        }

        print("Tagged style registry loaded \(styleBySongHash.count) hash entries from \(loadedSourceCount) JSON file(s).")
        return TaggedStyleRegistry(styleBySongHash: styleBySongHash)
    }

    private static func bundledTaggedJSONURLs() -> [URL] {
        var urls: [URL] = []
        var seenPaths = Set<String>()

        func appendJSONFiles(in directoryURL: URL, requireTaggedFolder: Bool) {
            guard let names = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }

            for fileURL in names where fileURL.pathExtension.lowercased() == "json" {
                if requireTaggedFolder,
                   fileURL.deletingLastPathComponent().lastPathComponent.lowercased() != taggedFolderName {
                    continue
                }

                let path = fileURL.standardizedFileURL.path
                if seenPaths.insert(path).inserted {
                    urls.append(fileURL)
                }
            }
        }

        for directoryURL in candidateTaggedDirectories() {
            appendJSONFiles(in: directoryURL, requireTaggedFolder: false)
            appendJSONFiles(in: directoryURL, requireTaggedFolder: true)
        }

        return urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func candidateTaggedDirectories() -> [URL] {
        var candidates: [URL] = []
        let fileManager = FileManager.default

        let sourceFileDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        candidates.append(sourceFileDirectory.appendingPathComponent(taggedFolderName))

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL)
            candidates.append(resourceURL.appendingPathComponent(taggedFolderName))
        }

        if let executableURL = Bundle.main.executableURL {
            let contentsURL = executableURL.deletingLastPathComponent()
            candidates.append(contentsURL)
            candidates.append(contentsURL.appendingPathComponent(taggedFolderName))
            let projectRootURL = contentsURL.deletingLastPathComponent().deletingLastPathComponent()
            candidates.append(projectRootURL)
            candidates.append(projectRootURL.appendingPathComponent("Dance Player").appendingPathComponent(taggedFolderName))
        }

        if let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dancePlayerSupportURL = applicationSupportURL.appendingPathComponent("DancePlayer", isDirectory: true)
            candidates.append(dancePlayerSupportURL)
            candidates.append(dancePlayerSupportURL.appendingPathComponent(taggedFolderName))
        }

        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(currentDirectoryURL)
        candidates.append(currentDirectoryURL.appendingPathComponent(taggedFolderName))
        candidates.append(currentDirectoryURL.appendingPathComponent("Dance Player").appendingPathComponent(taggedFolderName))
        candidates.append(currentDirectoryURL.appendingPathComponent("Dance Player").appendingPathComponent("Dance Player").appendingPathComponent(taggedFolderName))

        var uniqueCandidates: [URL] = []
        var seenPaths = Set<String>()

        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            guard seenPaths.insert(standardized.path).inserted else { continue }
            if FileManager.default.fileExists(atPath: standardized.path) {
                uniqueCandidates.append(standardized)
            }
        }

        return uniqueCandidates
    }

    func styleName(for songHash: String) -> String? {
        styleBySongHash[songHash]
    }
}

/// Which end of a Spotify track's trim is being auditioned.
enum SpotifyPreviewEdge {
    case start
    case end
}

/// Hidden from the ordinary Add menu; the floor hears the file's own title and danceStyles, not displayName — that's the joke.
struct CursedSong: Identifiable, CaseIterable {
    let id: String
    let displayName: String
    let subtitle: String
    let resourceName: String
    let fileExtension: String
    let danceStyles: Set<String>
    /// Filled in when the dance isn't on the predefined list, in which case `danceStyles` holds
    /// "Other" and this is what the floor is actually told.
    var customStyle: String = ""
    var knownBPM: Int? = nil

    /// Nil until the song has actually been added to the app bundle; the menu shows that rather than failing silently.
    var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: fileExtension, subdirectory: "audio files")
            ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
    }

    var isInstalled: Bool { bundledURL != nil }

    static let allCases: [CursedSong] = [
        CursedSong(
            id: "cursed-bnp",
            displayName: "Cursed BNP",
            subtitle: "Wally's \"normal version\". It is not normal.",
            resourceName: "BNP (Normal Version, Wally)",
            fileExtension: "mp3",
            danceStyles: ["Bohemian National Polka"]
        ),
        CursedSong(
            id: "romany-national-polka",
            displayName: "Romany National Polka",
            subtitle: "Two polkas that should never have met",
            resourceName: "Romany National Polka",
            fileExtension: "mp3",
            // Not on the predefined list, and deliberately not filed under Romany Polka: it
            // isn't that dance, and tagging it as one would offer the Romany Polka's intro.
            danceStyles: ["Other"],
            customStyle: "Romany National Polka"
        ),
        CursedSong(
            id: "helsinki-polka",
            displayName: "Tokyo Polka (Metal)",
            subtitle: "Hatsune Miku, with distortion pedals",
            resourceName: "helsinkipolka",
            fileExtension: "mp3",
            danceStyles: ["Tokyo Polka"]
        ),
        CursedSong(
            id: "nadie-como-tu-metal",
            displayName: "Nadie Como Tu (Metal Bachata)",
            subtitle: "A bachata that went completely wrong.",
            resourceName: "Nadie Como Tu (Bachata Version)",
            fileExtension: "mp3",
            danceStyles: ["Bachata"]
        ),
        CursedSong(
            id: "lose-control-accelerating",
            displayName: "Lose Control (Accelerating)",
            subtitle: "You Actually Lose Control®",
            resourceName: "Lose Control (Accelerating V 2.0)",
            fileExtension: "mp3",
            danceStyles: ["Accelerating Waltz"]
        ),
    ]
}

enum SpotifyImportKind {
    case track
    case playlist
}

/// Cached so the workbook import table can preview artwork before import without re-reading the file on every redraw.
@MainActor
enum PopularEditArtwork {
    private static var cache: [String: NSImage] = [:]

    static func cached(for edit: PopularEdit) -> NSImage? { cache[edit.id] }

    static func load(for edit: PopularEdit) async -> NSImage? {
        if let image = cache[edit.id] { return image }
        guard let url = edit.bundledURL else { return nil }

        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                cache[edit.id] = image
                return image
            }
        }
        return nil
    }
}

struct PopularEdit: Identifiable, CaseIterable {
    let id: String
    let displayName: String
    let resourceName: String
    let fileExtension: String
    let danceStyles: Set<String>
    /// Known tempo for shipped recordings; detection leaves it alone rather than overwriting it with an estimate.
    var knownBPM: Int? = nil

    var bundledURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: fileExtension, subdirectory: "audio files")
            ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
    }

    static let allCases: [PopularEdit] = [
        PopularEdit(
            id: "barbie-line-dance",
            displayName: "Barbie Line Dance",
            resourceName: "Barbie Line Dance",
            fileExtension: "mp3",
            danceStyles: ["Barbie Line Dance"],
            knownBPM: 110
        ),
        PopularEdit(
            id: "bohemian-national-polka",
            displayName: "Bohemian National Polka",
            resourceName: "Bohemian National Polka",
            fileExtension: "mp3",
            danceStyles: ["Bohemian National Polka"],
            knownBPM: 104
        ),
        PopularEdit(
            id: "dawn-mazurka",
            displayName: "Dawn Mazurka",
            resourceName: "Dawn Mazurka",
            fileExtension: "m4a",
            danceStyles: ["Dawn Mazurka"]
        ),
        PopularEdit(
            id: "romany-polka",
            displayName: "Romany Polka",
            resourceName: "Romany Polka",
            fileExtension: "mp3",
            danceStyles: ["Romany Polka"]
        ),
        PopularEdit(
            id: "tokyo-polka",
            displayName: "Tokyo Polka",
            resourceName: "Tokyo Polka - Hatsune Miku",
            fileExtension: "mp3",
            danceStyles: ["Tokyo Polka"],
            knownBPM: 120
        ),
        PopularEdit(
            id: "'t-smidje-mixer",
            displayName: "'T Smidje Mixer",
            resourceName: "TSmidje_Edit",
            fileExtension: "mp3",
            danceStyles: ["'T Smidje Mixer"]
        )
    ]
}

enum SpotifyServiceError: LocalizedError {
    case missingClientID
    case invalidSpotifyIdentifier
    case authorizationCancelled
    case missingAuthorizationCode
    case missingAccessToken
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Enter a Spotify Client ID first."
        case .invalidSpotifyIdentifier:
            return "That Spotify URL, URI, or ID was not recognized."
        case .authorizationCancelled:
            return "Spotify sign-in was cancelled."
        case .missingAuthorizationCode:
            return "Spotify did not return an authorization code."
        case .missingAccessToken:
            return "Spotify sign-in did not return an access token."
        case .requestFailed(let message):
            return message
        }
    }
}

struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct SpotifyToken {
    var accessToken: String
    var refreshToken: String?
    var expirationDate: Date

    var isValid: Bool {
        expirationDate.timeIntervalSinceNow > 60
    }
}

struct SpotifyImage: Decodable {
    let url: URL
}

struct SpotifyExternalURLs: Decodable {
    let spotify: String?
}

struct SpotifyArtist: Decodable {
    let name: String
}

struct SpotifyAPITrack: Decodable {
    let id: String
    let name: String
    let artists: [SpotifyArtist]
    let durationMs: Int
    let uri: String
    let externalUrls: SpotifyExternalURLs?
    let album: SpotifyAlbum?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case artists
        case durationMs = "duration_ms"
        case uri
        case externalUrls = "external_urls"
        case album
    }
}

struct SpotifyTrackSearchResponse: Decodable {
    let tracks: SpotifyTrackSearchPage
}

struct SpotifyTrackSearchPage: Decodable {
    let items: [SpotifyAPITrack]
}

struct SpotifyAlbum: Decodable {
    let images: [SpotifyImage]
}

    struct SpotifyPlaylistItemsPage: Decodable {
        let items: [SpotifyPlaylistItem]
        let total: Int
        let limit: Int
        let offset: Int
    }

struct SpotifyPlaylistItem: Decodable {
    let item: SpotifyAPITrack?

    enum CodingKeys: String, CodingKey {
        case item = "track"
    }
}

struct SpotifyDevicesResponse: Decodable {
    let devices: [SpotifyDevice]
}

struct SpotifyDevice: Decodable {
    let id: String?
    let name: String
    let isActive: Bool
    let isRestricted: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case isActive = "is_active"
        case isRestricted = "is_restricted"
    }
}

struct SpotifyPlaybackState: Decodable {
    let isPlaying: Bool
    let progressMs: Int?
    let item: SpotifyPlaybackItem?

    enum CodingKeys: String, CodingKey {
        case isPlaying = "is_playing"
        case progressMs = "progress_ms"
        case item
    }
}

struct SpotifyPlaybackItem: Decodable {
    let uri: String?
}

@MainActor
final class SpotifyCallbackListener {
    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var pendingResult: Result<URL, Error>?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }

        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            guard let callbackListener = self else { return }
            Task { @MainActor [callbackListener] in
                callbackListener.handle(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                guard let callbackListener = self else { return }
                Task { @MainActor [callbackListener] in
                    callbackListener.finish(.failure(error))
                }
            }
        }
        self.listener = listener
        listener.start(queue: .main)
    }

    func waitForCallback() async throws -> URL {
        if let pendingResult {
            self.pendingResult = nil
            return try pendingResult.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.finish(.failure(error))
                }
                return
            }

            guard
                let data,
                let request = String(data: data, encoding: .utf8),
                let firstLine = request.components(separatedBy: "\r\n").first,
                let path = firstLine.split(separator: " ").dropFirst().first,
                let callbackURL = URL(string: "http://127.0.0.1\(path)")
            else {
                Task { @MainActor [weak self] in
                    self?.finish(.failure(SpotifyServiceError.missingAuthorizationCode))
                }
                return
            }

            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html\r
            Connection: close\r
            \r
            <html><body>API connection enabled! You can close this window and return to the app.</body></html>
            """
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            Task { @MainActor [weak self] in
                self?.finish(.success(callbackURL))
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        listener?.cancel()
        listener = nil

        guard let continuation else {
            pendingResult = result
            return
        }
        self.continuation = nil

        switch result {
        case .success(let url):
            continuation.resume(returning: url)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

final class SpotifyService {
    private let redirectPort: UInt16 = 43879
    private var token: SpotifyToken?
    private var currentClientID: String?

    private var redirectURI: String {
        "http://127.0.0.1:\(redirectPort)/callback"
    }

    func connect(clientID: String) async throws {
        _ = try await accessToken(clientID: clientID)
    }

    func importTrack(from input: String, clientID: String) async throws -> Track {
        let id = try spotifyID(from: input, expectedKind: "track")
        let apiTrack: SpotifyAPITrack = try await apiRequest(
            URL(string: "https://api.spotify.com/v1/tracks/\(id)")!,
            clientID: clientID
        )
        return try await makeTrack(from: apiTrack)
    }

    func fetchPlaylistTrackURIs(from input: String) async throws -> [String] {
        let id = try spotifyID(from: input, expectedKind: "playlist")
        let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(id)")!
        var request = URLRequest(url: embedURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SpotifyServiceError.requestFailed("Could not read Spotify playlist page.")
        }

        let uriPattern = #"spotify:track:[A-Za-z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: uriPattern) else {
            throw SpotifyServiceError.requestFailed("Could not read Spotify playlist page.")
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var orderedURIs: [String] = []
        var seenURIs = Set<String>()

        for match in regex.matches(in: html, options: [], range: range) {
            guard let matchRange = Range(match.range, in: html) else { continue }
            let uri = String(html[matchRange])
            if seenURIs.insert(uri).inserted {
                orderedURIs.append(uri)
            }
        }

        guard !orderedURIs.isEmpty else {
            throw SpotifyServiceError.requestFailed("Could not find track IDs in the Spotify playlist embed.")
        }

        return orderedURIs
    }

    func importTracks(from inputs: [String], clientID: String) async throws -> [Track] {
        let ids = inputs.compactMap { try? spotifyID(from: $0, expectedKind: "track") }
        guard !ids.isEmpty else { return [] }

        var allTracks: [Track] = []
        for (index, id) in ids.enumerated() {
            let apiTrack: SpotifyAPITrack = try await apiRequest(
                URL(string: "https://api.spotify.com/v1/tracks/\(id)")!,
                clientID: clientID
            )
            allTracks.append(try await makeTrack(from: apiTrack))

            if index + 1 < ids.count {
                try? await Task.sleep(nanoseconds: 125_000_000)
            }
        }

        return allTracks
    }

    func searchTracks(query: String, clientID: String) async throws -> [Track] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: trimmedQuery),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "8")
        ]

        guard let url = components.url else {
            throw SpotifyServiceError.requestFailed("Could not build Spotify search URL.")
        }

        let response: SpotifyTrackSearchResponse = try await apiRequest(url, clientID: clientID)
        var results: [Track] = []
        for apiTrack in response.tracks.items {
            results.append(try await makeTrack(from: apiTrack))
        }
        return results
    }

    func startPlayback(uri: String, clientID: String?, position: TimeInterval = 0) async throws {
        guard let clientID = clientID ?? currentClientID else {
            throw SpotifyServiceError.missingClientID
        }

        let deviceID = try await playableDeviceID(clientID: clientID)
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/play")!
        if let deviceID {
            components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        }

        var request = try await authorizedRequest(
            components.url!,
            clientID: clientID
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "uris": [uri],
            "position_ms": max(0, Int(position * 1000))
        ])
        try await sendEmptyRequest(request)
    }

    func pausePlayback(clientID: String?) async throws {
        guard let clientID = clientID ?? currentClientID else {
            throw SpotifyServiceError.missingClientID
        }

        var request = try await authorizedRequest(
            URL(string: "https://api.spotify.com/v1/me/player/pause")!,
            clientID: clientID
        )
        request.httpMethod = "PUT"
        try await sendEmptyRequest(request)
    }

    func playbackState(clientID: String?) async throws -> SpotifyPlaybackState? {
        guard let clientID = clientID ?? currentClientID else {
            throw SpotifyServiceError.missingClientID
        }

        let request = try await authorizedRequest(
            URL(string: "https://api.spotify.com/v1/me/player")!,
            clientID: clientID
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 204 {
            return nil
        }

        try validate(response: response, data: data)
        return try JSONDecoder().decode(SpotifyPlaybackState.self, from: data)
    }

    private func apiRequest<T: Decodable>(_ url: URL, clientID: String, retryCount: Int = 0) async throws -> T {
        let request = try await authorizedRequest(url, clientID: clientID)
        let (data, response) = try await URLSession.shared.data(for: request)

        // Spotify can rate-limit right after a fresh token exchange, so retry instead of throwing immediately.
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429, retryCount < 3 {
            let retryAfterSeconds = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 1.0
            try await Task.sleep(nanoseconds: UInt64(max(0.5, retryAfterSeconds) * 1_000_000_000))
            return try await apiRequest(url, clientID: clientID, retryCount: retryCount + 1)
        }

        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorizedRequest(_ url: URL, clientID: String) async throws -> URLRequest {
        let accessToken = try await accessToken(clientID: clientID)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func sendEmptyRequest(_ request: URLRequest) async throws {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }
    
    private func playableDeviceID(clientID: String) async throws -> String? {
        let response: SpotifyDevicesResponse = try await apiRequest(
            URL(string: "https://api.spotify.com/v1/me/player/devices")!,
            clientID: clientID
        )

        guard let device = response.devices.first(where: { $0.isActive && !$0.isRestricted && $0.id != nil })
            ?? response.devices.first(where: { !$0.isRestricted && $0.id != nil })
        else {
            throw SpotifyServiceError.requestFailed("Open Spotify on this Mac or another device, start any song once, then try Play again.")
        }

        if !device.isActive, let deviceID = device.id {
            try await transferPlayback(to: deviceID, clientID: clientID)
        }

        return device.id
    }

    private func transferPlayback(to deviceID: String, clientID: String) async throws {
        var request = try await authorizedRequest(
            URL(string: "https://api.spotify.com/v1/me/player")!,
            clientID: clientID
        )
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_ids": [deviceID],
            "play": false
        ])
        try await sendEmptyRequest(request)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Spotify request failed."
            throw SpotifyServiceError.requestFailed("Spotify returned \(httpResponse.statusCode): \(body)")
        }
    }

    private func accessToken(clientID: String) async throws -> String {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            throw SpotifyServiceError.missingClientID
        }

        currentClientID = trimmedClientID

        if let token, token.isValid {
            return token.accessToken
        }

        let tokenResponse = try await authorize(clientID: trimmedClientID)
        let token = SpotifyToken(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
        self.token = token
        return token.accessToken
    }

    private func authorize(clientID: String) async throws -> SpotifyTokenResponse {
        let verifier = randomBase64URLString(byteCount: 64)
        let challenge = codeChallenge(for: verifier)
        let state = randomBase64URLString(byteCount: 16)
        let scopes = "playlist-read-private playlist-read-collaborative user-read-playback-state user-modify-playback-state"

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)
        ]

        guard let authURL = components.url else {
            throw SpotifyServiceError.requestFailed("Could not build Spotify sign-in URL.")
        }

        let listener = try await MainActor.run {
            let listener = SpotifyCallbackListener(port: redirectPort)
            try listener.start()
            return listener
        }

        let callbackTask = Task {
            try await listener.waitForCallback()
        }

        await MainActor.run {
            _ = NSWorkspace.shared.open(authURL)
        }

        let callbackURL = try await callbackTask.value
        let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        let returnedState = callbackComponents?.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == state else {
            throw SpotifyServiceError.authorizationCancelled
        }

        guard let code = callbackComponents?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyServiceError.missingAuthorizationCode
        }

        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "client_id": clientID,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
    }

    private func makeTrack(from apiTrack: SpotifyAPITrack) async throws -> Track {
        let externalURL = apiTrack.externalUrls?.spotify.flatMap(URL.init(string:))
        let artworkURL = apiTrack.album?.images.first?.url
        let artwork = await loadArtwork(from: artworkURL)
        let artist = apiTrack.artists.map(\.name).joined(separator: ", ")
        let duration = TimeInterval(apiTrack.durationMs) / 1000.0

        return Track(
            url: externalURL ?? URL(string: apiTrack.uri)!,
            title: apiTrack.name,
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            duration: duration,
            artwork: artwork,
            songHash: "spotify:\(apiTrack.id)",
            source: .spotify,
            spotifyURI: apiTrack.uri,
            spotifyExternalURL: externalURL
        )
    }

    private func loadArtwork(from url: URL?) async -> NSImage? {
        guard let url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }

    private func spotifyID(from input: String, expectedKind: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpotifyServiceError.invalidSpotifyIdentifier
        }

        if trimmed.hasPrefix("spotify:\(expectedKind):") {
            return String(trimmed.split(separator: ":").last ?? "")
        }

        if let url = URL(string: trimmed),
           url.host?.contains("spotify.com") == true {
            let components = url.pathComponents.filter { $0 != "/" }
            if let kindIndex = components.firstIndex(of: expectedKind),
               components.indices.contains(kindIndex + 1) {
                return components[kindIndex + 1]
            }
        }

        if trimmed.range(of: #"^[A-Za-z0-9]{16,}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        throw SpotifyServiceError.invalidSpotifyIdentifier
    }

    private func randomBase64URLString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }

    private func formBody(_ fields: [String: String]) -> Data {
        let body = fields
            .map { key, value in
                "\(urlEncode(key))=\(urlEncode(value))"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Direct-form-I biquad, used for the ITU-R BS.1770 K-weighting filter chain.
private struct Biquad {
    let b0, b1, b2, a1, a2: Double
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }

    /// Derived from the analog prototype so coefficients stay correct at any sample rate, matching BS.1770 exactly at 48kHz.
    static func kWeightingShelf(sampleRate: Double) -> Biquad {
        let gain = 3.999843853973347, q = 0.7071752369554196, cutoff = 1681.974450955533
        let k = tan(.pi * cutoff / sampleRate)
        let vh = pow(10.0, gain / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0
        )
    }

    /// Stage 2: RLB high-pass.
    static func kWeightingHighPass(sampleRate: Double) -> Biquad {
        let q = 0.5003270373238773, cutoff = 38.13547087602444
        let k = tan(.pi * cutoff / sampleRate)
        let a0 = 1.0 + k / q + k * k
        return Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0
        )
    }
}

// MARK: - High-resolution cover art

/// iTunes Search API serves art up to 3000x3000, versus Spotify's 640x640 cap.
enum ITunesArtworkLookup {
    /// The `100x100bb` segment of an artwork URL is a resize instruction, not a fixed asset,
    /// so any size up to 3000 can be requested. Anything larger is served as 3000.
    static let preferredSize = 2000

    private struct SearchResponse: Decodable {
        struct Result: Decodable {
            let trackName: String?
            let artistName: String?
            let collectionName: String?
            let artworkUrl100: String?
        }
        let results: [Result]
    }

    /// Several matches for one song, so the DJ picks the right release rather than having the
    /// first hit overwrite art they were happy with.
    static func candidates(title: String, artist: String, limit: Int = 6) async -> [ITunesArtworkCandidate] {
        var terms = [title]
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedArtist.isEmpty, trimmedArtist != "Unknown Artist" {
            terms.append(trimmedArtist)
        }

        let term = terms.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]

        guard let searchURL = components.url,
              let (data, _) = try? await URLSession.shared.data(from: searchURL),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return [] }

        var candidates: [ITunesArtworkCandidate] = []
        var seenAlbums = Set<String>()

        for result in response.results {
            guard let thumbnail = result.artworkUrl100 else { continue }

            // One entry per album — the same cover repeated is just noise to choose between.
            let album = result.collectionName ?? thumbnail
            guard seenAlbums.insert(album).inserted else { continue }

            let sized = thumbnail.replacingOccurrences(
                of: "100x100bb",
                with: "\(preferredSize)x\(preferredSize)bb"
            )
            guard let artworkURL = URL(string: sized),
                  let (imageData, _) = try? await URLSession.shared.data(from: artworkURL),
                  let image = NSImage(data: imageData)
            else { continue }

            candidates.append(ITunesArtworkCandidate(
                trackName: result.trackName ?? title,
                artistName: result.artistName ?? artist,
                albumName: result.collectionName ?? "",
                image: image
            ))
        }

        return candidates
    }
}

struct ITunesArtworkCandidate: Identifiable {
    let id = UUID()
    let trackName: String
    let artistName: String
    let albumName: String
    let image: NSImage

    var resolutionLabel: String {
        guard let size = image.pixelDimensions else { return "—" }
        return "\(size.width)×\(size.height)"
    }
}

// MARK: - Audio Engine & Controller
class PlayerController: ObservableObject {
    /// Bump when `measureLoudness`, `gainCorrection` or the target changes. v2: -14 LUFS,
    /// and the gain mix went from silently inert to actually applied.
    static let loudnessAnalysisVersion = 2

    /// Ramps are positioned on the file's own timeline (same as startTime/endTime) so they stay put when tempo scales playback.
    /// Parameters built with the plain initializer carry an invalid track ID and are dropped without error.
    static func audioMix(
        forGaindB gaindB: Double,
        trackID: CMPersistentTrackID,
        fadeIn: TimeInterval = 0,
        fadeOut: TimeInterval = 0,
        fadeInStart: TimeInterval = 0,
        fadeOutEnd: TimeInterval = 0
    ) -> AVMutableAudioMix {
        let mix = AVMutableAudioMix()
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID

        let gain = pow(10.0, Float(gaindB) / 20.0)

        func time(_ seconds: TimeInterval) -> CMTime {
            CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        }

        // Instructions must be set in ascending time order; a fade-in at time zero skips the initial level to avoid a collision.
        if fadeIn <= 0 || fadeInStart > 0 {
            parameters.setVolume(gain, at: .zero)
        }

        if fadeIn > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: 0,
                toEndVolume: gain,
                timeRange: CMTimeRange(start: time(fadeInStart), duration: time(fadeIn))
            )
        }

        if fadeOut > 0 {
            parameters.setVolumeRamp(
                fromStartVolume: gain,
                toEndVolume: 0,
                timeRange: CMTimeRange(start: time(fadeOutEnd - fadeOut), duration: time(fadeOut))
            )
        }

        mix.inputParameters = [parameters]
        return mix
    }

    static func audioMix(for track: Track, trackID: CMPersistentTrackID) -> AVMutableAudioMix {
        audioMix(
            forGaindB: track.gainCorrectiondB,
            trackID: trackID,
            fadeIn: track.effectiveFadeInDuration,
            fadeOut: track.effectiveFadeOutDuration,
            fadeInStart: track.startTime,
            fadeOutEnd: track.playbackStopTime
        )
    }

    /// Resolved per file so applying a gain needn't await an asset load at play time.
    private var audioTrackIDCache: [URL: CMPersistentTrackID] = [:]

    /// `then` runs synchronously on a cache hit, asynchronously the first time a file is seen this session, and always runs even if the track ID can't be resolved.
    private func applyAudioMix(
        for track: Track,
        to item: AVPlayerItem,
        then completion: (() -> Void)? = nil
    ) {
        let url = track.url
        if let trackID = audioTrackIDCache[url] {
            item.audioMix = Self.audioMix(for: track, trackID: trackID)
            completion?()
            return
        }

        let asset = item.asset
        Task { @MainActor [weak self] in
            let trackID = try? await asset.loadTracks(withMediaType: .audio).first?.trackID
            if let trackID {
                self?.audioTrackIDCache[url] = trackID
                item.audioMix = Self.audioMix(for: track, trackID: trackID)
            }
            completion?()
        }
    }

    /// Pre-resolves track IDs so the first play of any song is already levelled.
    private func warmAudioTrackIDCache() {
        let urls = tracks.filter { $0.source == .local }.map(\.url)
        Task { @MainActor [weak self] in
            for url in urls where self?.audioTrackIDCache[url] == nil {
                guard let trackID = try? await AVURLAsset(url: url)
                    .loadTracks(withMediaType: .audio).first?.trackID
                else { continue }
                self?.audioTrackIDCache[url] = trackID
            }
        }
    }

    /// Spotify API key, shared by the workbook importer and the settings UI.
    @Published var spotifyClientID: String = UserDefaults.standard.string(forKey: "spotifyClientID") ?? "" {
        didSet { UserDefaults.standard.set(spotifyClientID, forKey: "spotifyClientID") }
    }

    /// Menu-bar driven presentation, so File/Settings items work from anywhere in the app.
    @Published var isPresentingNewProject = false
    @Published var isPresentingAdvancedSettings = false
    @Published var isPresentingSpotifyKeyEditor = false
    @Published var isDisplayWindowOpen = false
    @Published var isCoverArtWindowOpen = false
    /// True between a jam finishing and the DJ moving on: the floor is already gathered, so
    /// the pivot call goes out before the next song is announced rather than after it.
    @Published var isShowingPivots = false

    @Published var pivotScreenEnabled: Bool = UserDefaults.standard.object(
        forKey: "DancePlayer.pivotScreenEnabled"
    ) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pivotScreenEnabled, forKey: "DancePlayer.pivotScreenEnabled")
            if !pivotScreenEnabled { isShowingPivots = false }
        }
    }

    /// The song whose timings are being edited, or nil when that window is closed.
    @Published var timingEditorTrackID: UUID? = nil

    @Published var isDraggingDivider = false
    @Published var isAdvancedSettingsOpen = false

    /// Per-frame work in the DJ view is paused while the divider is being dragged and while
    /// Advanced Settings is up. The audience screen is unaffected.
    var animationsEnabled: Bool {
        !isImportingContent && !isDraggingDivider && !isAdvancedSettingsOpen
    }

    @Published var isDetectingBPM = false
    @Published var bpmDetectionCompleted = 0
    @Published var bpmDetectionTotal = 0

    @Published var bpmDetectionOnImport: Bool =
        UserDefaults.standard.bool(forKey: "DancePlayer.bpmDetectionOnImport") {
        didSet {
            UserDefaults.standard.set(bpmDetectionOnImport, forKey: "DancePlayer.bpmDetectionOnImport")
        }
    }

    // MARK: - Undo

    private struct QueueSnapshot {
        let tracks: [Track]
        let currentTrackID: UUID?
        let label: String
    }

    /// Whole-queue snapshots rather than per-operation inverses: the queue is small, and a
    /// snapshot can't get out of step with the operation it's meant to reverse.
    private var undoStack: [QueueSnapshot] = []
    private var redoStack: [QueueSnapshot] = []
    private static let undoDepth = 25

    /// Drives the Edit menu's titles and enabled states.
    @Published var undoActionLabel: String? = nil
    @Published var redoActionLabel: String? = nil

    func recordUndoSnapshot(_ label: String) {
        push(&undoStack, QueueSnapshot(tracks: tracks, currentTrackID: currentTrack?.id, label: label))
        undoActionLabel = label

        // A fresh edit forks the history: anything on the redo stack was recorded against a
        // queue that no longer exists, and replaying it would drop this edit on the floor.
        redoStack.removeAll()
        redoActionLabel = nil
    }

    func undoLastChange() {
        guard let snapshot = undoStack.popLast() else { return }

        // Labelled with the action being reversed, so the menu reads "Redo Remove Song"
        // for the same edit the Undo item just named.
        push(&redoStack, QueueSnapshot(tracks: tracks, currentTrackID: currentTrack?.id, label: snapshot.label))
        redoActionLabel = snapshot.label

        restore(snapshot)
        undoActionLabel = undoStack.last?.label
    }

    func redoLastChange() {
        guard let snapshot = redoStack.popLast() else { return }

        push(&undoStack, QueueSnapshot(tracks: tracks, currentTrackID: currentTrack?.id, label: snapshot.label))
        undoActionLabel = snapshot.label

        restore(snapshot)
        redoActionLabel = redoStack.last?.label
    }

    private func push(_ stack: inout [QueueSnapshot], _ snapshot: QueueSnapshot) {
        stack.append(snapshot)
        if stack.count > Self.undoDepth { stack.removeFirst() }
    }

    private func restore(_ snapshot: QueueSnapshot) {
        tracks = snapshot.tracks
        // Followed by id — the restored queue may hold the song at a different position.
        currentIndex = snapshot.currentTrackID.flatMap { id in
            tracks.firstIndex(where: { $0.id == id })
        }

        if currentIndex == nil {
            avPlayer?.pause()
            isPlaying = false
        }

        // Focus must resign first, or a field mid-edit holds its own value and re-saves it over the undone state on close.
        if let editingID = selectedTrackForEditing?.id {
            NSApp.keyWindow?.makeFirstResponder(nil)
            selectedTrackForEditing = tracks.first(where: { $0.id == editingID })
        }

        synchronizeActiveTrackSettings()
        objectWillChange.send()
    }

    // MARK: - Set clock

    /// Deliberately not persisted — each night needs a fresh end time, not a stale one from before.
    @Published var isPresentingSetClockConfig = false
    @Published var setClockEndTime: Date? = nil
    /// The DJ's estimate of the gap between songs — announcements, finding a partner.
    @Published var setClockPauseSeconds: Double = 10

    /// Fixed on purpose, not configurable: a jam runs long because the floor circles up, and a
    /// mixer needs teaching time before it starts.
    static let jamAllowanceSeconds: Double = 4 * 60
    static let mixerAllowanceSeconds: Double = 90

    var isSetClockConfigured: Bool { setClockEndTime != nil }

    /// Songs still to come, counting the one playing now.
    private var setClockRemainingTracks: [Track] {
        let start = currentIndex ?? 0
        guard start < tracks.count else { return [] }
        return tracks[start...].filter { !$0.isSkipped }
    }

    var setClockRemainingSeconds: Double {
        let remaining = setClockRemainingTracks
        guard !remaining.isEmpty else { return 0 }

        var total = remaining.reduce(0.0) { $0 + $1.effectiveDuration }
        total += setClockPauseSeconds * Double(remaining.count)
        total += Self.jamAllowanceSeconds * Double(remaining.filter(\.isJam).count)
        total += Self.mixerAllowanceSeconds * Double(remaining.filter(\.countsAsMixer).count)

        // Don't re-count the part of the current song already played.
        if currentIndex != nil { total -= currentTime }

        return max(0, total)
    }

    var setClockProjectedEnd: Date {
        Date().addingTimeInterval(setClockRemainingSeconds)
    }

    /// Positive means the set is projected to run past the target.
    var setClockDeltaSeconds: Double? {
        guard let setClockEndTime else { return nil }
        return setClockProjectedEnd.timeIntervalSince(setClockEndTime)
    }

    @Published var projectName: String = "Dance Player Project"
    @Published var projectAutosaveParentURL: URL? = nil
    @Published var projectFolderURL: URL? = nil
    /// Destination `.dbdj` for a file-backed project — saves write here instead of leaving a
    /// project folder behind.
    @Published var projectFileURL: URL? = nil
    /// Unpacked working copy backing `projectFileURL`.
    private var projectWorkingFolderURL: URL? = nil
    private let projectSaveQueue = DispatchQueue(label: "dance-player.project-save", qos: .utility)
    @Published var autosaveEnabled = false
    @Published var hasLoadedProject = false
    @Published var showThankYouScreen = false
    /// Non-nil while the DJ is reviewing a parsed Dancebreak DJ Workbook — takes over the main pane.
    @Published var pendingWorkbookImport: [WorkbookImportRow]? = nil

    @Published var currentIndex: Int? = nil {
        didSet {
            updateNowPlayingInfo()
        }
    }
    @Published var isPlaying = false {
        didSet {
            updateNowPlayingInfo()
        }
    }
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    /// Matches typical streaming loudness; per-track gain is capped by peak headroom so quiet material won't clip.
    @Published var targetLoudnessLUFS: Double = -14.0
    @Published var isBatchProcessingLoudness = false
    @Published var loudnessBatchProgress: Double = 0.0
    /// A re-level asked for while one was already running, run once the current pass ends.
    private var isRelevelQueued = false
    /// `ContentView.onAppear` fires again on window changes; the launch pass runs once.
    private var hasRunLaunchRelevel = false
    
    @Published var lastTrack: Track? = nil
    @Published var isBetweenSongs = false
    @Published var selectedTrackForEditing: Track? = nil

    // MARK: - Advanced Settings
    /// Project-specific (always starts disabled for a new project). Single global toggle for showing manual BPM in the main control view.
    @Published var showTempo: Bool = false
    @Published var autoplayEnabled: Bool = false
    @Published var autoplayDelaySeconds: Double = 10.0
    /// Transient — true while the auto-advance timer is counting down toward the next song.
    @Published var autoplayCountdownActive: Bool = false
    /// Seconds left in the current autoplay countdown, ticking down once a second.
    @Published var autoplayCountdownRemaining: Double = 0

    /// The dance intro, on its own player so it can't disturb the cued song.
    @Published var isPlayingIntro = false
    private var introPlayer: AVPlayer?
    private var introFinishedObserver: NSObjectProtocol?
    private var introBoundaryObserver: Any?
    /// These are a handful of fixed recordings shipped with the app, scanned once and reused —
    /// not re-measured on every press.
    private var introAudibleDurationCache: [URL: TimeInterval] = [:]

    /// Which trim edge is being auditioned on Spotify, so the button can offer to stop it.
    @Published var spotifyPreviewEdge: SpotifyPreviewEdge? = nil
    private var spotifyPreviewTask: Task<Void, Never>?
    static let spotifyPreviewLength: TimeInterval = 5

    @Published var spotifyStatusMessage: String? = nil
    @Published var isSpotifyImporting = false
    @Published var isSpotifySearching = false
    @Published var spotifySearchResults: [Track] = []
    @Published var importStatusMessage: String? = nil
    @Published var activeImportOperations: Int = 0
    @Published var importTotalCount: Int = 0
    @Published var importCompletedCount: Int = 0
    @Published var tracks: [Track] = [] {
        didSet {
            // Forces a refresh sync down to all observing views when the collection shifts
            objectWillChange.send()
            scheduleProjectAutosave()
        }
    }
    
    private var spotifyAccumulatedPauseTime: TimeInterval = 0.0
    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var spotifyProgressTask: Task<Void, Never>?
    private var projectAutosaveTask: Task<Void, Never>?
    private var librarySaveTask: Task<Void, Never>?
    private var isPresentingCloseSavePrompt = false
    private var isHandlingSongEnd = false
    private var displayWindowController: NSWindowController?
    private var coverArtWindowController: NSWindowController?
    private var autoplayCountdownTask: Task<Void, Never>?
    private let spotifyService = SpotifyService()
    private var spacebarKeyMonitor: Any?
    
    var isDraggingSlider = false

    var currentTrack: Track? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }

    var firstPlayableIndex: Int? {
        tracks.firstIndex(where: { !$0.isSkipped })
    }

    var isImportingContent: Bool {
        activeImportOperations > 0 || isSpotifyImporting || isBatchProcessingLoudness
    }

    var importProgressFraction: Double? {
        guard importTotalCount > 0 else { return nil }
        return Double(importCompletedCount) / Double(importTotalCount)
    }

    var importProgressSummary: String? {
        guard importTotalCount > 0 else { return nil }
        return "Imported \(min(importCompletedCount, importTotalCount)) of \(importTotalCount) songs"
    }

    init() {
        setupRemoteCommandCenter()
        setupSpacebarKeyMonitor()
    }


    func beginImportActivity(message: String? = nil, totalCount: Int? = nil) {
        activeImportOperations += 1
        if let message {
            importStatusMessage = message
        }
        if let totalCount {
            importTotalCount = max(0, totalCount)
            importCompletedCount = 0
        }
    }

    func finishImportActivity() {
        activeImportOperations = max(0, activeImportOperations - 1)
        if activeImportOperations == 0, !isSpotifyImporting {
            importStatusMessage = nil
            importTotalCount = 0
            importCompletedCount = 0
        }
    }

    /// Switches a running import from a spinner to a determinate bar; kept separate from `beginImportActivity` so a late total doesn't open a second activity.
    func setImportTotal(_ total: Int, message: String? = nil) {
        guard activeImportOperations > 0 else { return }
        if let message { importStatusMessage = message }
        importTotalCount = max(0, total)
        importCompletedCount = 0
    }

    func advanceImportProgress() {
        guard importTotalCount > 0 else { return }
        importCompletedCount = min(importTotalCount, importCompletedCount + 1)
    }

    func isTrackSkipped(at index: Int) -> Bool {
        tracks.indices.contains(index) ? tracks[index].isSkipped : false
    }

    func playableIndex(after index: Int? = nil) -> Int? {
        let start = min((index ?? -1) + 1, tracks.count)
        guard start < tracks.count else { return nil }
        return tracks.indices.first(where: { $0 >= start && !tracks[$0].isSkipped })
    }

    func playableIndex(before index: Int? = nil) -> Int? {
        guard !tracks.isEmpty else { return nil }
        let start = min(index ?? tracks.count, tracks.count - 1)
        guard start >= 0 else { return nil }
        return tracks.indices.reversed().first(where: { $0 < start && !tracks[$0].isSkipped })
    }

    func queueNumber(for trackID: UUID) -> Int? {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }),
              !tracks[index].isSkipped else { return nil }
        return tracks.prefix(index + 1).filter { !$0.isSkipped }.count
    }

    /// Addressed by id, not index — indices go stale across reorders since ForEach reuses views rather than rebuilding them.
    func toggleSkipTrack(id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        toggleSkipTrack(at: index)
    }

    func removeTrack(id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        removeTrack(at: index)
    }

    /// One undo entry for the whole batch, not one per track — a multi-select delete is a
    /// single action from the DJ's point of view, and should take one ⌘Z to reverse.
    func removeTracks(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        recordUndoSnapshot(ids.count == 1 ? "Remove Song" : "Remove \(ids.count) Songs")

        for id in ids {
            guard let index = tracks.firstIndex(where: { $0.id == id }) else { continue }

            if currentIndex == index {
                avPlayer?.pause()
                avPlayer = nil
                stopSpotifyProgressMonitor()
                isPlaying = false
                currentTime = 0
                duration = 0
                currentIndex = nil
            } else if let cur = currentIndex, let removedIndex = tracks.firstIndex(where: { $0.id == id }), cur > removedIndex {
                currentIndex = cur - 1
            }

            let removed = tracks.remove(at: index)
            forgetLibraryEntry(songHash: removed.songHash)
        }
    }

    /// Same one-entry-per-batch rationale as `removeTracks`. Sets every track to the same
    /// skipped state rather than toggling each independently, since a mixed selection toggled
    /// would otherwise skip some and unskip others in one action.
    func setSkipped(_ skipped: Bool, forIDs ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        recordUndoSnapshot(skipped
            ? (ids.count == 1 ? "Skip Song" : "Skip \(ids.count) Songs")
            : (ids.count == 1 ? "Unskip Song" : "Unskip \(ids.count) Songs"))

        var mustAdvancePastCurrent = false
        for id in ids {
            guard let index = tracks.firstIndex(where: { $0.id == id }), tracks[index].isSkipped != skipped else { continue }
            tracks[index].isSkipped = skipped
            saveTrack(tracks[index])
            if skipped, currentIndex == index { mustAdvancePastCurrent = true }
        }
        scheduleProjectAutosave()
        objectWillChange.send()

        if mustAdvancePastCurrent, let current = currentIndex {
            if let nextPlayable = playableIndex(after: current) ?? playableIndex(before: current) {
                play(index: nextPlayable)
            } else {
                avPlayer?.pause()
                stopSpotifyProgressMonitor()
                isPlaying = false
                currentTime = 0
                duration = 0
                currentIndex = nil
            }
        }
    }

    func play(id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        play(index: index)
    }

    /// A row's live position, for the few places that reach into `tracks` directly.
    func trackIndex(for id: UUID) -> Int? {
        tracks.firstIndex(where: { $0.id == id })
    }

    func toggleSkipTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        recordUndoSnapshot(tracks[index].isSkipped ? "Unskip Song" : "Skip Song")

        tracks[index].isSkipped.toggle()
        saveTrack(tracks[index])
        scheduleProjectAutosave()
        objectWillChange.send()

        if tracks[index].isSkipped, currentIndex == index {
            if let nextPlayable = playableIndex(after: index) ?? playableIndex(before: index) {
                play(index: nextPlayable)
            } else {
                avPlayer?.pause()
                stopSpotifyProgressMonitor()
                isPlaying = false
                currentTime = 0
                duration = 0
                currentIndex = nil
                isBetweenSongs = false
            }
        }
    }

    // MARK: - Media Key / Keyboard Shortcuts (F7 / F8 / F9 + Spacebar)

    /// Routes hardware media keys (F7/F8/F9, Touch Bar, Control Center "Now Playing") to playback controls.

    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.playCommand.isEnabled = true
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.pauseCommand.isEnabled = true
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }

        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
    }

    private func teardownRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.togglePlayPauseCommand.removeTarget(nil)
        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)
    }

    private func updateNowPlayingInfo() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: track.effectiveDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? track.speedMultiplier : 0.0
        ]

        if let artwork = track.artwork {
            let mediaArtwork = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            info[MPMediaItemPropertyArtwork] = mediaArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Spacebar toggles play/pause, EXCEPT while the user is typing in any text field

    /// Escape, Return, Tab and the arrows, which AppKit still needs for dismissing sheets,
    /// firing default buttons and moving focus.
    private static let passthroughKeyCodes: Set<UInt16> = [53, 36, 76, 48, 123, 124, 125, 126]

    private func setupSpacebarKeyMonitor() {
        spacebarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            if self.isCurrentlyEditingText() {
                return event // let the text field handle it normally
            }

            // The timing editor runs its own preview transport; space there means "audition
            // this edit", not "start the set".
            if self.isTimingEditorPresented {
                return event
            }

            // Menu shortcuts belong to the menu bar.
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if modifiers.contains(.command) || modifiers.contains(.control) {
                return event
            }

            // keyCode 49 == spacebar
            if event.keyCode == 49 {
                self.togglePlayPause()
                return nil // swallow so it doesn't also trigger button focus / scroll, etc.
            }

            if Self.passthroughKeyCodes.contains(event.keyCode) {
                return event
            }

            // An unhandled key-down is what makes macOS beep.
            return nil
        }
    }

    private func isCurrentlyEditingText() -> Bool {
        guard let window = NSApp.keyWindow,
              let responder = window.firstResponder else { return false }

        // NSTextView backs both NSTextField editing sessions and SwiftUI's
        // TextField/TextEditor while they're focused.
        if responder is NSTextView { return true }

        return false
    }

    private var safeProjectName: String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Dance Player Project" : trimmed
    }

    private func sanitizeProjectName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalidCharacters).joined(separator: " ")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Dance Player Project" : trimmed
    }

    private var projectRootFolderURL: URL? {
        if let projectFolderURL {
            return projectFolderURL
        }

        // A file-backed (.dbdj) project keeps its unpacked working copy inside our own
        // storage; the folder the DJ chose only holds the .dbdj itself.
        if let projectWorkingFolderURL {
            return projectWorkingFolderURL
        }

        guard let parent = projectAutosaveParentURL else { return nil }
        return parent.appendingPathComponent(safeProjectName, isDirectory: true)
    }

    /// Container for the unpacked working copies of file-backed projects. Tracks reference
    /// their audio by URL, so this has to be durable storage rather than a temp directory.
    private var projectsWorkingParentURL: URL {
        let fileManager = FileManager.default
        let folder = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DancePlayer", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func freshWorkingFolderURL(named name: String) -> URL {
        projectsWorkingParentURL
            .appendingPathComponent("\(sanitizeProjectName(name))-\(UUID().uuidString)", isDirectory: true)
    }

    /// Points the project at a single `.dbdj` inside `folderURL` instead of a project folder.
    private func adoptProjectFile(named name: String, savingInto folderURL: URL) {
        let sanitizedName = sanitizeProjectName(name)
        projectFileURL = folderURL
            .appendingPathComponent("\(sanitizedName).\(Self.projectFileExtension)")
        projectWorkingFolderURL = freshWorkingFolderURL(named: sanitizedName)
        projectAutosaveParentURL = nil
        projectFolderURL = nil
        autosaveEnabled = true
        if let projectFileURL { ProjectLocations.noteRecentProject(projectFileURL) }
    }

    private var projectFilesFolderURL: URL? {
        projectRootFolderURL?.appendingPathComponent("files", isDirectory: true)
    }

    private var projectArtworkFolderURL: URL? {
        projectRootFolderURL?.appendingPathComponent("artwork", isDirectory: true)
    }

    /// Debounced because the library file inlines every track's artwork, making a save an expensive multi-megabyte encode.
    private var pendingLibrarySaveTrackID: UUID?

    func saveTrackSoon(_ track: Track) {
        pendingLibrarySaveTrackID = track.id
        librarySaveTask?.cancel()
        librarySaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushPendingTrackSave() }
        }
    }

    /// Always re-reads the track from the queue: the debounce may have outlived several edits,
    /// and the last state is the one worth keeping.
    func flushPendingTrackSave() {
        librarySaveTask?.cancel()
        librarySaveTask = nil

        guard let trackID = pendingLibrarySaveTrackID else { return }
        pendingLibrarySaveTrackID = nil

        if let track = tracks.first(where: { $0.id == trackID }) {
            saveTrack(track)
        }
    }

    private func scheduleProjectAutosave() {
        guard hasLoadedProject, autosaveEnabled, projectRootFolderURL != nil else { return }

        projectAutosaveTask?.cancel()
        projectAutosaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            await MainActor.run {
                self?.saveCurrentProjectPackage()
            }
        }
    }

    private func saveCurrentProjectPackage() {
        guard hasLoadedProject, autosaveEnabled, let destinationDirectoryURL = projectRootFolderURL else { return }
        let projectName = safeProjectName
        let projectFileDestination = projectFileURL

        // Backgrounded since a save is a full copy+encode pass over the whole library; serialized so overlapping saves can't tear the file.
        projectSaveQueue.async { [weak self] in
            guard let self else { return }
            do {
                let projectFolderURL = try self.exportProjectPackage(
                    toProjectFolder: destinationDirectoryURL,
                    projectName: projectName,
                    overwriteExisting: true
                )

                // File-backed project: the folder above is only our working copy, so pack it
                // into the .dbdj the DJ actually sees.
                if let projectFileDestination {
                    try self.writeProjectFile(from: projectFolderURL, to: projectFileDestination)
                }
            } catch {
                print("Failed autosaving project package: \(error.localizedDescription)")
            }
        }
    }

    /// Staged in a temp file first, since the sandbox only grants write access to the picked file itself, not a sibling temp in its folder.
    private func writeProjectFile(from projectFolderURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        let scratchURL = projectsWorkingParentURL
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")

        try ZipArchive.zip(contentsOf: projectFolderURL, to: scratchURL)

        let accessedScope = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessedScope { destinationURL.stopAccessingSecurityScopedResource() }
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            try overwriteFile(at: destinationURL, withContentsOf: scratchURL)
        } else {
            // A path we just created ourselves (Save As) — the move is allowed.
            try fileManager.moveItem(at: scratchURL, to: destinationURL)
            return
        }

        try? fileManager.removeItem(at: scratchURL)
    }

    /// Streams `sourceURL` over an existing file, chunk by chunk, so a 180MB project doesn't
    /// have to be held in memory to be saved.
    private func overwriteFile(at destinationURL: URL, withContentsOf sourceURL: URL) throws {
        let reader = try FileHandle(forReadingFrom: sourceURL)
        defer { try? reader.close() }

        let writer = try FileHandle(forWritingTo: destinationURL)
        defer { try? writer.close() }

        try writer.truncate(atOffset: 0)

        while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
            try writer.write(contentsOf: chunk)
        }
    }

    /// Filed as DJ-chosen art, the category written into the project and library cache — so it's
    /// on disk immediately and never needs the network again. Spotify tracks included.
    func applyChosenArtwork(_ artwork: NSImage, toTrackID id: UUID) {
        guard let index = trackIndex(for: id) else { return }

        tracks[index].artwork = artwork
        tracks[index].hasCustomArtwork = true
        saveTrack(tracks[index])

        if currentIndex == index {
            updateNowPlayingInfo()
        }
    }

    /// Unloads the project on last-window-close since the app keeps running and would otherwise reopen with it still loaded.
    func closeProjectAfterLastWindowClosed() {
        guard hasLoadedProject else { return }

        // Queued while the tracks are still in place; the export reads them off the queue.
        projectAutosaveTask?.cancel()
        projectAutosaveTask = nil
        saveCurrentProjectPackage()

        // Back to the welcome screen immediately: a large project takes seconds to write, and
        // reopening inside that window used to bring back the project just closed.
        hasLoadedProject = false
        autosaveEnabled = false
        stopPlaybackForUnload()

        // Emptied only once the save has read it; same serial queue, so it can't overtake.
        projectSaveQueue.async { [weak self] in
            DispatchQueue.main.async { self?.clearLoadedProject() }
        }
    }

    private func stopPlaybackForUnload() {
        avPlayer?.pause()
        removeTimeObserver()
        avPlayer = nil
        stopSpotifyProgressMonitor()
        pauseAutoplayCountdown()
        closeDisplayWindow()

        isPlaying = false
        isBetweenSongs = false
        showThankYouScreen = false
        currentIndex = nil
        lastTrack = nil
        currentTime = 0
        duration = 0
        selectedTrackForEditing = nil
        pendingWorkbookImport = nil
    }

    private func clearLoadedProject() {
        tracks.removeAll()
        projectFolderURL = nil
        projectFileURL = nil
        projectWorkingFolderURL = nil
        projectAutosaveParentURL = nil
        hasRunLaunchRelevel = false
    }

    /// Save is a debounced background re-zip that quitting could otherwise cut off mid-write; runs on the serial save queue.
    func flushPendingSaves(completion: @escaping () -> Void) {
        projectAutosaveTask?.cancel()
        projectAutosaveTask = nil

        flushPendingTrackSave()
        saveCurrentProjectPackage()

        projectSaveQueue.async {
            DispatchQueue.main.async(execute: completion)
        }
    }

    func saveProjectOnCloseIfNeeded() {
        guard hasLoadedProject else { return }

        if autosaveEnabled {
            saveCurrentProjectPackage()
            return
        }

        guard !isPresentingCloseSavePrompt else { return }
        isPresentingCloseSavePrompt = true
        guard let destinationDirectoryURL = projectCloseSaveParentURL() else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Save Project?"
        alert.informativeText = "Do you want to save changes before closing?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                _ = try exportProjectPackage(
                    toProjectFolder: destinationDirectoryURL,
                    projectName: safeProjectName,
                    overwriteExisting: true
                )
            } catch {
                print("Failed saving project on close: \(error.localizedDescription)")
            }
        case .alertSecondButtonReturn:
            break
        default:
            break
        }

        isPresentingCloseSavePrompt = false
    }

    private func projectCloseSaveParentURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        let folder = appSupport
            .appendingPathComponent("DancePlayer", isDirectory: true)
            .appendingPathComponent("SavedProjects", isDirectory: true)

        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func ensureDirectoryExists(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func removeStaleLocalAudioCopies(
        songHash: String,
        keepingFileName fileNameToKeep: String,
        in folderURL: URL
    ) {
        let fileManager = FileManager.default
        let safeHash = songHash.replacingOccurrences(of: ":", with: "_")

        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil
        ) else { return }

        for fileURL in contents {
            let name = fileURL.lastPathComponent
            guard name != fileNameToKeep else { continue }
            guard name.hasPrefix("\(safeHash).") else { continue }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func writeStandaloneProjectArtworkIfNeeded(
        artwork: NSImage?,
        songHash: String
    ) -> String? {
        guard let artwork, let projectArtworkFolderURL else { return nil }

        do {
            try ensureDirectoryExists(at: projectArtworkFolderURL)
            let fileName = "\(songHash).png"
            let destinationURL = projectArtworkFolderURL.appendingPathComponent(fileName)

            if let data = artwork.projectPackageData {
                try data.write(to: destinationURL, options: .atomic)
                return fileName
            }
        } catch {
            print("Failed writing artwork asset: \(error.localizedDescription)")
        }

        return nil
    }

    /// Cover art embedded in an audio file's own metadata.
    private func embeddedArtwork(for url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    /// True when `url` lives inside the app bundle — i.e. a shipped Popular Edit.
    private func isBundledResource(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path)
    }

    /// Keyed by content hash, not URL, since older imports copied the file into the project and repointed track.url at the copy.
    private lazy var bundledPopularEditFileNames: [String: String] = {
        var result: [String: String] = [:]
        for edit in PopularEdit.allCases {
            guard let url = popularEditResourceURL(for: edit) else { continue }
            result[hashAudioFile(url)] = url.lastPathComponent
        }
        return result
    }()

    /// The bundled file backing this track, if the app already ships its audio.
    /// The Popular Edit a track came from, matched by the bundled file it plays.
    func popularEdit(for track: Track) -> PopularEdit? {
        guard let fileName = bundledFileName(for: track) else { return nil }
        return PopularEdit.allCases.first {
            "\($0.resourceName).\($0.fileExtension)" == fileName
        }
    }

    private func bundledFileName(for track: Track) -> String? {
        if let fileName = bundledPopularEditFileNames[track.songHash] { return fileName }
        if track.url.isFileURL, isBundledResource(track.url) { return track.url.lastPathComponent }
        return nil
    }

    /// A track's audio comes either from the app bundle (Popular Edits, referenced by name)
    /// or from the project's own `files/` folder.
    private func resolvedAudioURL(for packageTrack: ProjectPackageTrack, filesFolderURL: URL) -> URL? {
        if let bundledFileName = packageTrack.bundledFileName {
            let name = (bundledFileName as NSString).deletingPathExtension
            let fileExtension = (bundledFileName as NSString).pathExtension
            if let bundledURL = Bundle.main.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "audio files"
            ) ?? Bundle.main.url(forResource: name, withExtension: fileExtension) {
                return bundledURL
            }
            // Fall through: an older build may not ship this edit, but the project might
            // still carry a copy of it.
        }

        guard let fileName = packageTrack.localFileName else { return nil }
        let fileURL = filesFolderURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    private func projectArtworkImage(
        from packageTrack: ProjectPackageTrack,
        artworkFolderURL: URL
    ) -> NSImage? {
        if let artworkFileName = packageTrack.artworkFileName {
            let fileURL = artworkFolderURL.appendingPathComponent(artworkFileName)
            if let image = NSImage(contentsOf: fileURL) {
                return image
            }
        }

        if let artworkData = packageTrack.artworkData {
            return NSImage(data: artworkData)
        }

        return nil
    }

    private func materializeLocalTrackAssetsIfNeeded(
        _ track: inout Track,
        sourceURL: URL,
        artwork: NSImage?
    ) {
        guard let projectFilesFolderURL else { return }

        do {
            // Needed here since the first track add can happen before autosave has created these directories.
            try ensureDirectoryExists(at: projectFilesFolderURL)
            if let projectArtworkFolderURL {
                try ensureDirectoryExists(at: projectArtworkFolderURL)
            }

            let destinationFileName = projectPackageFileName(for: track)
            let destinationAudioURL = projectFilesFolderURL.appendingPathComponent(destinationFileName)

            // Safety net: drop any stale copy of this track under a different
            // file extension, so we never keep two on-disk copies for one song.
            removeStaleLocalAudioCopies(
                songHash: track.songHash,
                keepingFileName: destinationFileName,
                in: projectFilesFolderURL
            )

            // Popular Edits play straight from the bundle rather than being copied, since the audio already ships with the app.
            if !isBundledResource(sourceURL) {
                if sourceURL.standardizedFileURL != destinationAudioURL.standardizedFileURL {
                    if FileManager.default.fileExists(atPath: destinationAudioURL.path) {
                        try FileManager.default.removeItem(at: destinationAudioURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationAudioURL)
                }
                track.url = destinationAudioURL
            }

            if let artwork,
               let artworkData = artwork.projectPackageData,
               let projectArtworkFolderURL {
                let artworkFileName = "\(track.songHash).png"
                let artworkURL = projectArtworkFolderURL.appendingPathComponent(artworkFileName)
                try artworkData.write(to: artworkURL, options: .atomic)
                track.artwork = NSImage(contentsOf: artworkURL) ?? artwork
            }
        } catch {
            print("Failed materializing track into project folder: \(error.localizedDescription)")
        }
    }
    
    var upNextTracks: [Track] {
        let playableTracks = tracks.filter { !$0.isSkipped }
        guard let idx = currentIndex else { return Array(playableTracks.prefix(3)) }
        guard let start = playableIndex(after: idx) else { return [] }
        return Array(tracks[start..<tracks.count].filter { !$0.isSkipped }.prefix(3))
    }
    
    deinit {
        removeTimeObserver()
        spotifyProgressTask?.cancel()
        projectAutosaveTask?.cancel()
        if let spacebarKeyMonitor {
            NSEvent.removeMonitor(spacebarKeyMonitor)
        }
        teardownRemoteCommandCenter()
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
    
    func prepareTrack(index: Int, autoPlay: Bool, previousTrackOverride: Track? = nil) {
        guard tracks.indices.contains(index) else { return }
        guard !tracks[index].isSkipped else {
            if let fallbackIndex = playableIndex(after: index) ?? playableIndex(before: index) {
                prepareTrack(index: fallbackIndex, autoPlay: autoPlay, previousTrackOverride: previousTrackOverride)
            }
            return
        }
        isHandlingSongEnd = false
        pauseAutoplayCountdown()

        let previousTrack = previousTrackOverride ?? currentTrack
        removeTimeObserver()
        stopSpotifyProgressMonitor()
        stopIntro()
        showThankYouScreen = false
        isShowingPivots = false
        currentIndex = index
        let track = tracks[index]

        if track.source == .spotify {
            avPlayer?.pause()
            avPlayer = nil
            duration = track.effectiveDuration
            currentTime = 0

            self.spotifyAccumulatedPauseTime = 0.0
            
            if autoPlay {
                isBetweenSongs = false
                isPlaying = true
                playSpotifyTrack(track)
            } else {
                isPlaying = false
            }
            return
        }

        if previousTrack?.source == .spotify {
            pauseSpotifyPlayback()
        }
        
        let playerItem = AVPlayerItem(url: track.url)

        // Preserves vocal & instrumental pitch perfectly when scaling playback rate
        playerItem.audioTimePitchAlgorithm = .spectral

        // A gain cached under an older analysis version isn't trusted — play flat and re-measure rather than apply it.
        let mixTrack: Track
        if track.loudnessAnalysisVersion >= Self.loudnessAnalysisVersion {
            mixTrack = track
        } else {
            calculateLoudness(forTrackAt: index)
            var flatTrack = track
            flatTrack.gainCorrectiondB = 0
            mixTrack = flatTrack
        }

        avPlayer = AVPlayer(playerItem: playerItem)
        
        // Initialize layout constraints using custom modified length properties
        duration = track.effectiveDuration
        currentTime = 0
        
        // Snap playback directly to the user's custom start boundary
        let startCMTime = CMTime(seconds: track.startTime, preferredTimescale: 600)
        avPlayer?.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        let observerTrackID = track.id
        timeObserverToken = avPlayer?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self,
                  let currentTrack = self.currentTrack,
                  currentTrack.id == observerTrackID
            else { return }
            
            let absoluteSeconds = time.seconds
            
            let relativeSeconds = max(0, (absoluteSeconds - currentTrack.startTime) * currentTrack.speedMultiplier)
            
            // Skipped while suppressed — republishing 20x a second re-renders everything.
            if !self.isDraggingSlider, self.animationsEnabled {
                self.currentTime = relativeSeconds
            }
            
            // Stop and cycle sequence when crossing custom end timestamp barriers
            if absoluteSeconds >= currentTrack.playbackStopTime {
                self.handleSongEnded()
            }
        }
        
        // Mix must attach before playback starts — a fade shorter than the async track-ID load would finish before the ramp exists, playing at full volume instead.
        applyAudioMix(for: mixTrack, to: playerItem) { [weak self] in
            guard autoPlay, let self, self.currentTrack?.id == track.id else { return }

            self.isBetweenSongs = false
            self.avPlayer?.play()
            self.avPlayer?.rate = Float(track.speedMultiplier) // Initialize target tempo scale
            self.isPlaying = true
            self.reportPlaybackPosition(requested: track.startTime, label: "cue and play")
        }

        if !autoPlay {
            isPlaying = false
        }
    }
    
    // MARK: - Isolated ReplayGain Target Processing

    /// Re-derives gain after a tempo change: resynthesis overshoots peaks even though loudness barely moves, so cached headroom can no longer be trusted.
    func relevelGainForTempoChange(trackID: UUID) {
        guard let index = trackIndex(for: trackID), tracks[index].source == .local else { return }
        let track = tracks[index]

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let measurement = self.measureLoudnessAtPlaybackSpeed(of: track)
            else { return }

            let correction = self.gainCorrection(
                forLoudness: measurement.loudness,
                peak: measurement.peak
            )

            DispatchQueue.main.async {
                // Dropped if the tempo moved again while this was measuring — a later pass
                // will have the right answer.
                guard let index = self.trackIndex(for: trackID),
                      self.tracks[index].tempoPercentage == track.tempoPercentage
                else { return }

                self.tracks[index].gainCorrectiondB = correction
                self.saveTrack(self.tracks[index])

                if self.currentIndex == index, let item = self.avPlayer?.currentItem {
                    self.applyAudioMix(for: self.tracks[index], to: item)
                }

                print(String(
                    format: "Re-levelled '%@' for %+.1f%% tempo: %.1f LUFS peak %.2f, %+.1f dB",
                    track.title, track.tempoPercentage,
                    measurement.loudness, measurement.peak, correction
                ))
            }
        }
    }

    /// Measures loudness as actually played (trimmed and time-stretched); skips the vocoder and reads the file directly when tempo is unchanged.
    private func measureLoudnessAtPlaybackSpeed(of track: Track) -> (loudness: Double, peak: Float)? {
        guard track.tempoPercentage != 0 else { return measureLoudness(of: track) }

        let asset = AVURLAsset(url: track.url)

        // Blocking is fine here: this only ever runs on the measurement queue.
        let ready = DispatchSemaphore(value: 0)
        var sourceTrack: AVAssetTrack?
        var assetDuration: CMTime = .zero
        Task {
            sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first
            assetDuration = (try? await asset.load(.duration)) ?? .zero
            ready.signal()
        }
        ready.wait()

        guard let sourceTrack, assetDuration.seconds > 0 else { return nil }

        let start = CMTime(seconds: track.startTime, preferredTimescale: 600)
        let end = CMTime(seconds: track.endTime ?? assetDuration.seconds, preferredTimescale: 600)
        let playedRange = CMTimeRange(start: start, end: end)
        guard playedRange.duration.seconds > 0 else { return nil }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ), (try? compositionTrack.insertTimeRange(playedRange, of: sourceTrack, at: .zero)) != nil
        else { return nil }

        let stretched = CMTime(
            seconds: playedRange.duration.seconds / track.speedMultiplier,
            preferredTimescale: 600
        )
        compositionTrack.scaleTimeRange(
            CMTimeRange(start: .zero, duration: playedRange.duration),
            toDuration: stretched
        )

        guard let reader = try? AVAssetReader(asset: composition) else { return nil }

        let sampleRate = 48000.0
        let channelCount = 2
        let output = AVAssetReaderAudioMixOutput(
            audioTracks: composition.tracks(withMediaType: .audio),
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
            ]
        )
        output.audioTimePitchAlgorithm = .spectral
        reader.add(output)
        reader.startReading()

        var shelf = [Biquad](repeating: .kWeightingShelf(sampleRate: sampleRate), count: channelCount)
        var highPass = [Biquad](repeating: .kWeightingHighPass(sampleRate: sampleRate), count: channelCount)
        let segmentFrames = Int((sampleRate * 0.1).rounded())
        var segmentEnergy = [[Double]](repeating: [], count: channelCount)
        var runningEnergy = [Double](repeating: 0, count: channelCount)
        var framesInSegment = 0
        var peak: Float = 0

        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            )
            guard let pointer else { continue }

            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for frame in stride(from: 0, to: length / 4, by: channelCount) {
                    for channel in 0..<channelCount {
                        let sample = samples[frame + channel]
                        peak = max(peak, abs(sample))
                        let weighted = highPass[channel].process(shelf[channel].process(Double(sample)))
                        runningEnergy[channel] += weighted * weighted
                    }
                    framesInSegment += 1
                    if framesInSegment == segmentFrames {
                        for channel in 0..<channelCount {
                            segmentEnergy[channel].append(runningEnergy[channel])
                            runningEnergy[channel] = 0
                        }
                        framesInSegment = 0
                    }
                }
            }
        }

        return Self.gatedLoudness(
            segmentEnergy: segmentEnergy,
            segmentFrames: segmentFrames,
            peak: peak
        )
    }

    private func measureLoudness(of track: Track) -> (loudness: Double, peak: Float)? {
        guard let file = try? AVAudioFile(forReading: track.url) else { return nil }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0, file.length > 0 else { return nil }

        let firstFrame = max(0, Int64(track.startTime * sampleRate))
        let lastFrame = min(file.length, track.endTime.map { Int64($0 * sampleRate) } ?? file.length)
        guard lastFrame > firstFrame else { return nil }

        let readCapacity: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCapacity) else { return nil }

        var shelf = [Biquad](repeating: .kWeightingShelf(sampleRate: sampleRate), count: channelCount)
        var highPass = [Biquad](repeating: .kWeightingHighPass(sampleRate: sampleRate), count: channelCount)

        // Accumulate energy in 100ms segments; a 400ms block is then any 4 consecutive
        // segments, which gives the 75% overlap R128 asks for without buffering the file.
        let segmentFrames = Int((sampleRate * 0.1).rounded())
        var segmentEnergy = [[Double]](repeating: [], count: channelCount)
        var runningEnergy = [Double](repeating: 0, count: channelCount)
        var framesInSegment = 0
        var peak: Float = 0
        var frame = firstFrame
        file.framePosition = firstFrame

        while frame < lastFrame {
            let readLength = AVAudioFrameCount(min(Int64(readCapacity), lastFrame - frame))
            do {
                try file.read(into: buffer, frameCount: readLength)
            } catch {
                break
            }
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }

            let sampleCount = Int(buffer.frameLength)
            for sampleIndex in 0..<sampleCount {
                for channel in 0..<channelCount {
                    let sample = channels[channel][sampleIndex]
                    peak = max(peak, abs(sample))
                    let weighted = highPass[channel].process(shelf[channel].process(Double(sample)))
                    runningEnergy[channel] += weighted * weighted
                }
                framesInSegment += 1
                if framesInSegment == segmentFrames {
                    for channel in 0..<channelCount {
                        segmentEnergy[channel].append(runningEnergy[channel])
                        runningEnergy[channel] = 0
                    }
                    framesInSegment = 0
                }
            }
            frame += Int64(sampleCount)
        }

        return Self.gatedLoudness(
            segmentEnergy: segmentEnergy,
            segmentFrames: segmentFrames,
            peak: peak
        )
    }

    /// Shared BS.1770 gating stage so the file reader and tempo-stretched reader can't drift apart in their thresholds.
    private static func gatedLoudness(
        segmentEnergy: [[Double]],
        segmentFrames: Int,
        peak: Float
    ) -> (loudness: Double, peak: Float)? {
        guard let channelCount = segmentEnergy.first.map({ _ in segmentEnergy.count }),
              let segmentCount = segmentEnergy.first?.count,
              segmentCount >= 4
        else { return nil }

        var blockLoudness: [Double] = []
        for start in 0...(segmentCount - 4) {
            // Channel weighting G is 1.0 for mono and left/right, which is all we handle.
            var meanSquare = 0.0
            for channel in 0..<channelCount {
                var energy = 0.0
                for segment in start..<(start + 4) { energy += segmentEnergy[channel][segment] }
                meanSquare += energy / Double(4 * segmentFrames)
            }
            if meanSquare > 0 {
                blockLoudness.append(-0.691 + 10.0 * log10(meanSquare))
            }
        }
        guard !blockLoudness.isEmpty else { return nil }

        func gatedMean(_ blocks: [Double]) -> Double {
            let energy = blocks.reduce(0.0) { $0 + pow(10.0, ($1 + 0.691) / 10.0) } / Double(blocks.count)
            return -0.691 + 10.0 * log10(energy)
        }

        // Gating keeps silence and quiet passages from dragging the average down, which is
        // what makes a track with a long intro or fade-out measure as "quiet".
        let aboveAbsoluteGate = blockLoudness.filter { $0 > -70.0 }
        guard !aboveAbsoluteGate.isEmpty else { return nil }

        let relativeGate = gatedMean(aboveAbsoluteGate) - 10.0
        let gated = aboveAbsoluteGate.filter { $0 > relativeGate }
        return (gatedMean(gated.isEmpty ? aboveAbsoluteGate : gated), peak)
    }

    // MARK: - BPM detection

    /// Autocorrelation over a spectral-flux onset envelope, weighted by a tempo prior; accurate to about 1 BPM on test tracks.
    func detectBPM(of track: Track) -> Double? {
        guard !track.hasVariableTempo else { return nil }
        // A shipped edit with a published tempo is authoritative; don't estimate over it.
        if let known = popularEdit(for: track)?.knownBPM { return Double(known) }
        guard let file = try? AVAudioFile(forReading: track.url) else { return nil }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        guard sampleRate > 0, channelCount > 0, file.length > 0 else { return nil }

        let firstFrame = max(0, Int64(track.startTime * sampleRate))
        let lastFrame = min(file.length, track.endTime.map { Int64($0 * sampleRate) } ?? file.length)
        guard lastFrame > firstFrame else { return nil }

        // 2048-sample window, hop chosen for an ~86Hz envelope whatever the file's rate.
        let fftSize = 2048
        let hop = max(1, Int((sampleRate / 86.0).rounded()))
        let envelopeRate = sampleRate / Double(hop)

        guard let onsets = Self.spectralFluxEnvelope(
            file: file,
            firstFrame: firstFrame,
            lastFrame: lastFrame,
            channelCount: channelCount,
            fftSize: fftSize,
            hop: hop
        ), onsets.count > 16 else { return nil }

        return Self.tempo(
            fromOnsets: onsets,
            envelopeRate: envelopeRate,
            expectedRange: guidelineTempoRange(forStyles: track.danceStyles)
        )
    }

    private static func spectralFluxEnvelope(
        file: AVAudioFile,
        firstFrame: Int64,
        lastFrame: Int64,
        channelCount: Int,
        fftSize: Int,
        hop: Int
    ) -> [Double]? {
        let format = file.processingFormat
        let readCapacity: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readCapacity) else { return nil }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Denormalized: peak 1.0. The normalized variant scales the window down by ~1/N,
        // and log1p is nonlinear, so that scale would change the flux profile itself.
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_DENORM))

        let halfSize = fftSize / 2
        var real = [Float](repeating: 0, count: halfSize)
        var imaginary = [Float](repeating: 0, count: halfSize)
        var magnitudesSquared = [Float](repeating: 0, count: halfSize)

        var pending: [Float] = []          // mono samples not yet consumed by a frame
        var windowed = [Float](repeating: 0, count: fftSize)
        // Log magnitudes are kept between frames rather than recomputed: the previous frame's
        // values are already known, which halves the transcendental work.
        var logMagnitude = [Float](repeating: 0, count: halfSize + 1)
        var previousLogMagnitude = [Float](repeating: 0, count: halfSize + 1)
        var magnitude = [Float](repeating: 0, count: halfSize + 1)
        var rectified = [Float](repeating: 0, count: halfSize + 1)
        var havePrevious = false
        var flux: [Double] = []
        var binCount = Int32(halfSize + 1)
        var interiorCount = Int32(halfSize - 1)
        var halfScale: Float = 0.5
        var zero: Float = 0

        var frame = firstFrame
        file.framePosition = firstFrame

        while frame < lastFrame {
            let readLength = AVAudioFrameCount(min(Int64(readCapacity), lastFrame - frame))
            do { try file.read(into: buffer, frameCount: readLength) } catch { break }
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }

            let sampleCount = Int(buffer.frameLength)
            pending.reserveCapacity(pending.count + sampleCount)
            for index in 0..<sampleCount {
                var mono: Float = 0
                for channel in 0..<channelCount { mono += channels[channel][index] }
                pending.append(mono / Float(channelCount))
            }
            frame += Int64(sampleCount)

            var offset = 0
            while pending.count - offset >= fftSize {
                pending.withUnsafeBufferPointer { source in
                    windowed.withUnsafeMutableBufferPointer { destination in
                        vDSP_vmul(source.baseAddress! + offset, 1, window, 1,
                                  destination.baseAddress!, 1, vDSP_Length(fftSize))
                    }
                }

                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!,
                                                    imagp: imaginaryPointer.baseAddress!)
                        windowed.withUnsafeBufferPointer { input in
                            input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfSize))
                            }
                        }
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvmags(&split, 1, &magnitudesSquared, 1, vDSP_Length(halfSize))
                    }
                }

                // vDSP packs DC in real[0] and Nyquist in imag[0], and returns twice the
                // unnormalized transform — hence the halving.
                magnitudesSquared.withUnsafeBufferPointer { squared in
                    magnitude.withUnsafeMutableBufferPointer { mag in
                        vvsqrtf(mag.baseAddress! + 1, squared.baseAddress! + 1, &interiorCount)
                        vDSP_vsmul(mag.baseAddress! + 1, 1, &halfScale,
                                   mag.baseAddress! + 1, 1, vDSP_Length(halfSize - 1))
                    }
                }
                magnitude[0] = abs(real[0]) * 0.5
                magnitude[halfSize] = abs(imaginary[0]) * 0.5

                // log1p compresses dynamics so a loud passage doesn't dominate the envelope.
                magnitude.withUnsafeBufferPointer { mag in
                    logMagnitude.withUnsafeMutableBufferPointer { logMag in
                        vvlog1pf(logMag.baseAddress!, mag.baseAddress!, &binCount)
                    }
                }

                if havePrevious {
                    var rise: Float = 0
                    // vDSP_vsub computes C = B - A, so previous goes first.
                    vDSP_vsub(previousLogMagnitude, 1, logMagnitude, 1,
                              &rectified, 1, vDSP_Length(halfSize + 1))
                    vDSP_vthres(rectified, 1, &zero, &rectified, 1, vDSP_Length(halfSize + 1))
                    vDSP_sve(rectified, 1, &rise, vDSP_Length(halfSize + 1))
                    flux.append(Double(rise))
                }
                swap(&previousLogMagnitude, &logMagnitude)
                havePrevious = true

                offset += hop
            }

            if offset > 0 { pending.removeFirst(offset) }
        }

        guard !flux.isEmpty else { return nil }
        let mean = flux.reduce(0, +) / Double(flux.count)
        return flux.map { $0 - mean }
    }

    /// Social-dance music lives here; anything outside is an octave error, not a tempo.
    static let detectableBPMRange: ClosedRange<Double> = 60...210

    /// Adjusts by octaves (powers of two) only; prefers the style window, then the nearest value within 5 BPM below it, ties going to the faster reading.
    static func octaveFitted(
        _ bpm: Double,
        to range: ClosedRange<Double>?,
        score: ((Double) -> Double)? = nil
    ) -> Double {
        guard let range, !range.contains(bpm) else { return bpm }

        func distance(from candidate: Double) -> Double {
            if range.contains(candidate) { return 0 }
            return candidate < range.lowerBound
                ? range.lowerBound - candidate
                : candidate - range.upperBound
        }

        let octaves = [1.0, 2.0, 0.5, 4.0, 0.25]
            .map { bpm * $0 }
            .filter { $0 >= detectableBPMRange.lowerBound && $0 <= detectableBPMRange.upperBound }
        guard !octaves.isEmpty else { return bpm }

        let inside = octaves.filter { range.contains($0) }
        if !inside.isEmpty {
            guard let score else { return inside.min() ?? bpm }
            return inside.max { score($0) < score($1) } ?? bpm
        }

        if let slowestNearby = octaves.filter({ distance(from: $0) <= 5 }).min() {
            return slowestNearby
        }

        return octaves.min {
            let left = distance(from: $0), right = distance(from: $1)
            return left == right ? $0 > $1 : left < right
        } ?? bpm
    }

    private static func tempo(
        fromOnsets onsets: [Double],
        envelopeRate: Double,
        expectedRange: ClosedRange<Double>?
    ) -> Double? {
        let minBPM = Self.detectableBPMRange.lowerBound
        let maxBPM = Self.detectableBPMRange.upperBound
        let priorBPM = 120.0, priorSigma = 0.9

        let lowestLag = max(2, Int((envelopeRate * 60.0 / maxBPM).rounded()))
        let highestLag = min(onsets.count - 2, Int((envelopeRate * 60.0 / minBPM).rounded()))
        guard highestLag > lowestLag else { return nil }

        // Needed out to 4x the longest candidate for the comb score.
        let maxNeededLag = min(onsets.count - 1, highestLag * 4)
        var autocorrelation = [Double](repeating: 0, count: maxNeededLag + 1)
        onsets.withUnsafeBufferPointer { samples in
            guard let base = samples.baseAddress else { return }
            for lag in 0...maxNeededLag {
                var sum = 0.0
                vDSP_dotprD(base, 1, base + lag, 1, &sum, vDSP_Length(onsets.count - lag))
                autocorrelation[lag] = sum / Double(onsets.count - lag)
            }
        }
        guard autocorrelation[0] > 0 else { return nil }
        let normalizer = autocorrelation[0]
        for lag in autocorrelation.indices { autocorrelation[lag] /= normalizer }

        var scores = [Double](repeating: 0, count: highestLag - lowestLag + 1)
        for (offset, lag) in (lowestLag...highestLag).enumerated() {
            let bpm = 60.0 * envelopeRate / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / priorBPM) / priorSigma, 2))

            var combSum = 0.0
            var combCount = 0
            for multiple in 1...4 {
                let harmonic = lag * multiple
                if harmonic < autocorrelation.count {
                    combSum += autocorrelation[harmonic]
                    combCount += 1
                }
            }
            let comb = combSum / Double(max(combCount, 1))

            scores[offset] = (autocorrelation[lag] * 0.5 + comb * 0.5) * prior
        }

        guard let bestOffset = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        var lag = Double(lowestLag + bestOffset)

        // Parabolic interpolation across the peak, for sub-lag precision.
        if bestOffset > 0, bestOffset < scores.count - 1 {
            let before = scores[bestOffset - 1]
            let peak = scores[bestOffset]
            let after = scores[bestOffset + 1]
            let denominator = before - 2 * peak + after
            if denominator != 0 {
                lag += 0.5 * (before - after) / denominator
            }
        }

        guard lag > 0 else { return nil }

        func interpolated(_ lag: Double) -> Double {
            guard lag >= 1, lag < Double(autocorrelation.count - 1) else { return 0 }
            let index = Int(lag)
            let fraction = lag - Double(index)
            return autocorrelation[index] * (1 - fraction) + autocorrelation[index + 1] * fraction
        }

        /// Comb strength for a tempo: the autocorrelation summed over the lag's harmonics.
        func combScore(forBPM bpm: Double) -> Double {
            let candidateLag = 60.0 * envelopeRate / bpm
            var total = 0.0
            var weight = 0.0
            for multiple in 1...4 {
                let harmonic = candidateLag * Double(multiple)
                guard harmonic < Double(autocorrelation.count - 1) else { break }
                let harmonicWeight = Double(multiple)
                total += interpolated(harmonic) * harmonicWeight
                weight += harmonicWeight
            }
            return weight > 0 ? total / weight : -.infinity
        }

        let chosenBPM = octaveFitted(
            60.0 * envelopeRate / lag,
            to: expectedRange,
            score: combScore(forBPM:)
        )

        // One lag step is ~2.7 BPM at 120, so refine on a fine grid scored by the harmonic
        // comb — an error in the fundamental is multiplied at 2x/3x/4x.
        let coarseBPM = chosenBPM
        var refinedBPM = coarseBPM
        var bestRefinedScore = -Double.infinity

        var candidate = max(minBPM, coarseBPM - 4.0)
        let ceiling = min(maxBPM, coarseBPM + 4.0)
        while candidate <= ceiling {
            let normalized = combScore(forBPM: candidate)
            if normalized > bestRefinedScore {
                bestRefinedScore = normalized
                refinedBPM = candidate
            }
            candidate += 0.02
        }

        return refinedBPM
    }

    /// Detected BPM always rounds to a whole number; a DJ-typed decimal is preserved since these fields are free text.
    static func formatBPM(_ bpm: Double) -> String {
        String(Int(bpm.rounded()))
    }

    /// Fills in BPM for every local song. Run from the Tools menu or ⌘B, and automatically at
    /// import when the Advanced Settings toggle is on.
    func detectBPMForLibrary(overwritingExisting: Bool = true) {
        // Local files only. A streamed track has no samples to measure, and Spotify closed its
        // audio-features endpoint — the one source of a tempo figure — to new apps in late 2024.
        let targets = tracks.filter {
            $0.source == .local
                && !$0.hasVariableTempo
                && (overwritingExisting || $0.manualBPM.isEmpty)
        }
        guard !targets.isEmpty, !isDetectingBPM else { return }

        // Tracks its own progress separately since the import overlay lives behind the Advanced Settings sheet.
        isDetectingBPM = true
        bpmDetectionCompleted = 0
        bpmDetectionTotal = targets.count
        beginImportActivity(message: "Detecting BPM…", totalCount: targets.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // One song per core. Each detection is self-contained — it opens its own file and
            // touches no shared state — so this is a straight wall-clock win on the whole set.
            DispatchQueue.concurrentPerform(iterations: targets.count) { position in
                let track = targets[position]
                let detected = self.detectBPM(of: track)

                DispatchQueue.main.async {
                    self.advanceImportProgress()
                    self.bpmDetectionCompleted += 1

                    guard let detected, let index = self.trackIndex(for: track.id) else { return }
                    self.tracks[index].manualBPM = Self.formatBPM(detected)
                    self.saveTrack(self.tracks[index])
                }
            }

            DispatchQueue.main.async {
                self.finishImportActivity()
                self.isDetectingBPM = false
                self.bpmDetectionCompleted = 0
                self.bpmDetectionTotal = 0
            }
        }
    }

    // MARK: - Dynamics compression

    /// Where rendered copies live. Kept outside the project so the original import is never
    /// touched; the project package copies whatever the track points at when it saves.
    private static var compressedAudioFolderURL: URL? {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }

        let folder = appSupport
            .appendingPathComponent("DancePlayer", isDirectory: true)
            .appendingPathComponent("Compressed", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// How much louder the track still needs to be after the peak-limited boost is spent.
    /// Anything above ~1dB is worth compressing for; below that it isn't audible.
    private func loudnessDeficitdB(loudness: Double, peak: Float) -> Double {
        let needed = targetLoudnessLUFS - loudness
        guard needed > 0 else { return 0 }
        return max(0, needed - gainCorrection(forLoudness: loudness, peak: peak))
    }

    /// Renders once at import, local files only, as lossless ALAC.
    // MARK: - Seekable audio

    /// Compared on a background queue, so its conformances have to be free of the main actor.
    nonisolated enum MP3BitrateMode: Equatable, Sendable {
        case constant
        case variable
        case notMP3
    }

    /// Frame-header walk, no decoding: each header says how long its own frame is, so the file
    /// can be stepped through by arithmetic.
    static func mp3BitrateMode(of url: URL) -> MP3BitrateMode {
        guard url.pathExtension.lowercased() == "mp3",
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count > 10
        else { return .notMP3 }

        var offset = 0
        // ID3v2 sits in front of the audio; its length is a syncsafe integer, so each byte
        // carries only seven bits.
        if data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 {
            offset = 10
                + (Int(data[6] & 0x7f) << 21) + (Int(data[7] & 0x7f) << 14)
                + (Int(data[8] & 0x7f) << 7) + Int(data[9] & 0x7f)
        }

        let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0]
        let sampleRates = [44100, 48000, 32000, 0]

        var framesPerBitrate: [Int: Int] = [:]
        var framesRead = 0

        while offset + 4 < data.count, framesRead < 20_000 {
            guard data[offset] == 0xFF, data[offset + 1] & 0xE0 == 0xE0 else {
                offset += 1
                continue
            }

            let bitrate = bitrates[Int(data[offset + 2] >> 4) & 0xF]
            let sampleRate = sampleRates[Int(data[offset + 2] >> 2) & 0x3]
            guard bitrate > 0, sampleRate > 0 else { break }

            framesPerBitrate[bitrate, default: 0] += 1
            framesRead += 1

            let padding = Int(data[offset + 2] >> 1) & 0x1
            let frameLength = 144_000 * bitrate / sampleRate + padding
            guard frameLength > 4 else { break }
            offset += frameLength
        }

        // A lone frame at an odd rate is the Xing/Info header the encoder writes in front of
        // the audio, and says nothing about the rest of the file.
        let sustained = framesPerBitrate.filter { $0.value > 2 }
        guard !sustained.isEmpty else { return .notMP3 }
        return sustained.count > 1 ? .variable : .constant
    }

    /// AVFoundation seeks VBR MP3s by estimated bitrate rather than an index, drifting off target (measured -0.29s at 15s, -0.81s at 4min).
    /// A one-time lossless re-render fixes this; CBR files and Popular Edits already seek exactly and are left alone.
    func ensureSeekableAudio() {
        let candidates = tracks.filter {
            $0.source == .local
                && $0.url.pathExtension.lowercased() == "mp3"
                && !isBundledResource($0.url)
        }
        guard !candidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            for track in candidates {
                guard Self.mp3BitrateMode(of: track.url) == .variable,
                      let rendered = self.renderSeekableCopy(of: track)
                else { continue }

                DispatchQueue.main.async {
                    // Dropped if the song has gone, or if something else moved it in the
                    // meantime — the compressor writes its own render and can get there first.
                    guard let index = self.trackIndex(for: track.id),
                          self.tracks[index].url == track.url
                    else { return }

                    self.preserveArtworkBeforeAudioSwap(index: index)
                    self.tracks[index].url = rendered
                    self.saveTrack(self.tracks[index])
                    self.recueIfLoadedAudioIsStale(index: index)
                }
            }
        }
    }

    /// Stores custom artwork before the audio is swapped for a render, since renders carry no tags and it couldn't be re-read afterward.
    private func preserveArtworkBeforeAudioSwap(index: Int) {
        guard tracks.indices.contains(index),
              tracks[index].artwork != nil,
              !tracks[index].hasCustomArtwork
        else { return }

        tracks[index].hasCustomArtwork = true
    }

    private func renderSeekableCopy(of track: Track) -> URL? {
        guard let folder = Self.compressedAudioFolderURL,
              let sourceFile = try? AVAudioFile(forReading: track.url)
        else { return nil }

        let format = sourceFile.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0, sourceFile.length > 0 else { return nil }

        let destination = folder.appendingPathComponent(
            "\(track.songHash.replacingOccurrences(of: ":", with: "_"))-seekable.m4a"
        )

        // Reused across launches if the length matches, avoiding minutes of re-rendering; a truncated render is redone.
        let sourceDuration = Double(sourceFile.length) / format.sampleRate
        if let existing = try? AVAudioFile(forReading: destination) {
            let existingDuration = Double(existing.length) / existing.processingFormat.sampleRate
            if abs(existingDuration - sourceDuration) < 0.1 { return destination }
        }
        try? FileManager.default.removeItem(at: destination)

        // Explicitly 16-bit; inferring from the 32-bit float reading format would bloat the file to about 9x the source instead of 3x.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitDepthHintKey: 16,
        ]

        let blockSize: AVAudioFrameCount = 65536
        guard let outputFile = try? AVAudioFile(forWriting: destination, settings: settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize)
        else { return nil }

        while sourceFile.framePosition < sourceFile.length {
            let remaining = sourceFile.length - sourceFile.framePosition
            do {
                try sourceFile.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(blockSize), remaining)))
                guard buffer.frameLength > 0 else { break }
                try outputFile.write(from: buffer)
            } catch {
                print("Failed rendering a seekable copy of '\(track.title)': \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }

        print(String(
            format: "Rendered a seekable copy of '%@' (%.0fs of variable-bitrate MP3)",
            track.title, sourceDuration
        ))
        return destination
    }

    private func renderCompressedCopy(of track: Track, loudness: Double, peak: Float) -> URL? {
        let deficit = loudnessDeficitdB(loudness: loudness, peak: peak)
        guard deficit > 1.0, peak > 0 else { return nil }

        guard let sourceFile = try? AVAudioFile(forReading: track.url),
              let folder = Self.compressedAudioFolderURL
        else { return nil }

        let format = sourceFile.processingFormat
        let channelCount = Int(format.channelCount)
        guard format.sampleRate > 0, channelCount > 0, sourceFile.length > 0 else { return nil }

        // Order matters: gain first, then compression — compressing before makeup gain wouldn't touch the loudness or catch the peak.
        let makeupdB = min(12.0, targetLoudnessLUFS - loudness)
        let makeup = pow(10.0, makeupdB / 20.0)
        let ceiling = 0.98

        // Instant attack, so the ceiling can't be exceeded; 50ms release keeps the gain
        // reduction from pumping between beats.
        let release = exp(-1.0 / (0.050 * format.sampleRate))

        let destinationURL = folder.appendingPathComponent(
            "\(track.songHash.replacingOccurrences(of: ":", with: "_")).m4a"
        )
        try? FileManager.default.removeItem(at: destinationURL)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channelCount,
        ]
        guard let outputFile = try? AVAudioFile(forWriting: destinationURL, settings: outputSettings)
        else { return nil }

        let chunk: AVAudioFrameCount = 65536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }

        // One envelope across all channels, so the limiter never shifts the stereo image.
        var envelope = 0.0
        var maxReductiondB = 0.0

        while sourceFile.framePosition < sourceFile.length {
            do { try sourceFile.read(into: buffer, frameCount: chunk) } catch { break }
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }

            for frame in 0..<Int(buffer.frameLength) {
                var loudest = 0.0
                for channel in 0..<channelCount {
                    loudest = max(loudest, abs(Double(channels[channel][frame]) * makeup))
                }

                envelope = max(loudest, envelope * release)
                let reduction = envelope > ceiling ? ceiling / envelope : 1.0
                if reduction < 1 {
                    maxReductiondB = max(maxReductiondB, -20.0 * log10(reduction))
                }

                for channel in 0..<channelCount {
                    channels[channel][frame] = Float(Double(channels[channel][frame]) * makeup * reduction)
                }
            }

            do { try outputFile.write(from: buffer) } catch { return nil }
        }

        print(String(
            format: "Limited '%@': %+.1f dB makeup, %.1f dB max reduction",
            track.title, makeupdB, maxReductiondB
        ))
        return destinationURL
    }

    /// Re-derived from a stored measurement when the original peak wasn't kept. Peak only
    /// caps a boost, so attenuation is exact; a boost returns nil and must be re-measured.
    private func gainCorrection(forLoudness loudness: Double) -> Double? {
        let needed = targetLoudnessLUFS - loudness
        guard needed <= 0 else { return nil }
        return max(needed, -24.0)
    }

    /// Headroom may be negative — an already over-ceiling source gets pulled down rather than left unboosted.
    private func gainCorrection(forLoudness loudness: Double, peak: Float) -> Double {
        let needed = targetLoudnessLUFS - loudness
        let peakHeadroomdB = peak > 0 ? 20.0 * log10(Double(0.98 / peak)) : 12.0
        return min(max(needed, -24.0), min(12.0, peakHeadroomdB))
    }

    private func calculateLoudness(forTrackAt index: Int) {
        guard tracks.indices.contains(index) else { return }
        let track = tracks[index]

        // Streamed tracks have no local samples to analyze; Spotify normalizes its own playback.
        guard track.source == .local else { return }

        // Skip if the cache already holds a measurement from the current analysis version.
        if track.measuredLoudness != nil, track.loudnessAnalysisVersion >= Self.loudnessAnalysisVersion { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard var measurement = self.measureLoudness(of: track) else {
                print("Could not measure loudness for '\(track.title)'")
                return
            }

            // Gain alone can't always reach target — compress once at import so the gain path finishes from a crest factor with headroom to spare.
            var playbackURL = track.url
            if let compressedURL = self.renderCompressedCopy(
                of: track,
                loudness: measurement.loudness,
                peak: measurement.peak
            ) {
                var compressedTrack = track
                compressedTrack.url = compressedURL

                if let remeasured = self.measureLoudness(of: compressedTrack) {
                    let before = self.loudnessDeficitdB(loudness: measurement.loudness, peak: measurement.peak)
                    let after = self.loudnessDeficitdB(loudness: remeasured.loudness, peak: remeasured.peak)
                    print(String(
                        format: "Compressed '%@': %.1f LUFS peak %.2f -> %.1f LUFS peak %.2f (short by %.1f dB, now %.1f)",
                        track.title, measurement.loudness, measurement.peak,
                        remeasured.loudness, remeasured.peak, before, after
                    ))
                    measurement = remeasured
                    playbackURL = compressedURL
                } else {
                    try? FileManager.default.removeItem(at: compressedURL)
                }
            }

            let neededCorrection = self.gainCorrection(forLoudness: measurement.loudness, peak: measurement.peak)

            // Same background pass — the file is already being decoded for loudness.
            let detectedBPM = self.bpmDetectionOnImport ? self.detectBPM(of: track) : nil

            DispatchQueue.main.async {
                // Verify structural index integrity hasn't changed mid-thread
                guard self.tracks.indices.contains(index), self.tracks[index].id == track.id else { return }

                if playbackURL != self.tracks[index].url {
                    self.preserveArtworkBeforeAudioSwap(index: index)
                }
                self.tracks[index].url = playbackURL
                if self.bpmDetectionOnImport, self.tracks[index].manualBPM.isEmpty, let bpm = detectedBPM {
                    self.tracks[index].manualBPM = Self.formatBPM(bpm)
                }
                self.tracks[index].measuredLoudness = measurement.loudness
                self.tracks[index].gainCorrectiondB = neededCorrection
                self.tracks[index].loudnessAnalysisVersion = Self.loudnessAnalysisVersion
                print("Auto-calculated ReplayGain for '\(track.title)': \(String(format: "%.1f LUFS, %+.1f dB", measurement.loudness, neededCorrection))")

                // If the user happens to already be playing this track, update engine mix immediately
                if self.currentIndex == index, let item = self.avPlayer?.currentItem {
                    self.applyAudioMix(for: self.tracks[index], to: item)
                }
                self.recueIfLoadedAudioIsStale(index: index)

                self.saveTrack(self.tracks[index])
            }
        }
    }
    
    func play(index: Int) {
        guard tracks.indices.contains(index) else { return }
        if tracks[index].isSkipped {
            if let fallbackIndex = playableIndex(after: index) ?? playableIndex(before: index) {
                prepareTrack(index: fallbackIndex, autoPlay: true)
            }
            return
        }
        prepareTrack(index: index, autoPlay: true)
    }
    
    func handleSongEnded() {

        guard !isHandlingSongEnd else { return }
        isHandlingSongEnd = true

        stopSpotifyProgressMonitor()
        guard let currentIdx = currentIndex else {
            isHandlingSongEnd = false
            return
        }
        let endedTrack = currentTrack

        lastTrack = currentTrack

        if let nextPlayable = playableIndex(after: currentIdx) {

            currentIndex = nextPlayable
            duration = tracks[nextPlayable].effectiveDuration
            currentTime = 0
            isPlaying = false
            isBetweenSongs = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.prepareTrack(index: nextPlayable, autoPlay: false, previousTrackOverride: endedTrack)
                self.isHandlingSongEnd = false

                // Raised after `prepareTrack`, which clears it — the pivot call belongs to the
                // jam that just finished, not to the song now cued behind it.
                if self.pivotScreenEnabled, endedTrack?.isJam == true {
                    self.isShowingPivots = true
                    return
                }

                // prepareTrack() clears any pending countdown, so schedule the new one after it runs.
                self.scheduleAutoplayCountdownIfNeeded()
            }
        } else {
            avPlayer?.pause()
            if endedTrack?.source == .spotify {
                pauseSpotifyPlayback()
            }
            isPlaying = false
            currentTime = 0
            isBetweenSongs = false
            showThankYouScreen = true
            isHandlingSongEnd = false
        }
    }
    
    /// Stops the autoplay countdown without advancing, leaving the pane waiting for manual play, same as autoplay being off.
    func pauseAutoplayCountdown() {
        autoplayCountdownTask?.cancel()
        autoplayCountdownTask = nil
        if autoplayCountdownActive {
            autoplayCountdownActive = false
        }
        autoplayCountdownRemaining = 0
    }

    /// No-op unless Autoplay is enabled in Advanced Settings; ticks `autoplayCountdownRemaining` once a second for the UI.
    private func scheduleAutoplayCountdownIfNeeded() {
        pauseAutoplayCountdown()
        guard autoplayEnabled, isBetweenSongs else { return }

        // Skips autoplay while waiting on a person (pivot pairing or jam) rather than a timer, since only the DJ can see it's happened.
        guard !isShowingPivots, currentTrack?.isJam != true else { return }

        autoplayCountdownActive = true
        autoplayCountdownRemaining = autoplayDelaySeconds
        autoplayCountdownTask = Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }

                let remaining = await MainActor.run { () -> Double in
                    self.autoplayCountdownRemaining = max(0, self.autoplayCountdownRemaining - 1)
                    return self.autoplayCountdownRemaining
                }

                if remaining <= 0 {
                    await MainActor.run {
                        guard self.autoplayCountdownActive else { return }
                        self.beginNextTrackFromBetweenSongs()
                    }
                    return
                }
            }
        }
    }

    /// The "resume playback" behavior when the DJ (or the autoplay timer) advances out of the
    /// between-songs pane straight into the next prepared track.
    private func beginNextTrackFromBetweenSongs() {
        stopIntro()
        autoplayCountdownTask?.cancel()
        autoplayCountdownTask = nil
        isBetweenSongs = false
        autoplayCountdownActive = false
        autoplayCountdownRemaining = 0
        if let track = currentTrack, track.source == .spotify {
            if isPlaying {
                let absolutePauseTime = track.startTime + self.currentTime
                if let idx = currentIndex {
                    // Update our internal model cache with this position
                    self.tracks[idx].startTime = absolutePauseTime
                    self.saveTrack(self.tracks[idx])
                }

                stopSpotifyProgressMonitor()
                pauseSpotifyPlayback()
                isPlaying = false
            } else {
                playSpotifyTrack(track)
                isPlaying = true
            }
        } else {
            if let track = currentTrack {
                let startCMTime = CMTime(seconds: track.startTime, preferredTimescale: 600)
                avPlayer?.seek(to: startCMTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            avPlayer?.play()
            if let speed = currentTrack?.speedMultiplier {
                avPlayer?.rate = Float(speed)
            }
            isPlaying = true
        }
    }

    func togglePlayPause() {
        // Advancing past the pivot call announces the next song; the press after that starts
        // it. Autoplay is deliberately not counting down while it's up.
        if isShowingPivots {
            isShowingPivots = false
            scheduleAutoplayCountdownIfNeeded()
            return
        }

        if isBetweenSongs {
            // Nothing is playing between songs, so this always means "play now"; aborting is the separate "Abort Auto-Play" action.
            beginNextTrackFromBetweenSongs()
            return
        }

        if let track = currentTrack, track.source == .spotify {
            if isPlaying {
                stopSpotifyProgressMonitor()
                pauseSpotifyPlayback()
                isPlaying = false
            } else {
                if track.isSkipped {
                    if let nextPlayable = playableIndex(after: currentIndex) ?? playableIndex(before: currentIndex) {
                        play(index: nextPlayable)
                        return
                    }
                } else {
                    playSpotifyTrack(track)
                    isPlaying = true
                    return
                }
            }
            return
        }
        
        guard avPlayer != nil else {
            if let idx = currentIndex, tracks.indices.contains(idx), tracks[idx].source == .spotify {
                play(index: idx)
            } else if let firstPlayableIndex {
                play(index: firstPlayableIndex)
            }
            return
        }
        
        if isPlaying {
            avPlayer?.pause()
            isPlaying = false
        } else {
            let parked = avPlayer?.currentTime().seconds ?? 0
            avPlayer?.play()
            if let speed = currentTrack?.speedMultiplier {
                avPlayer?.rate = Float(speed) // Maintain tempo changes on resume
            }
            isPlaying = true
            reportPlaybackPosition(requested: parked, label: "transport resume")
        }
    }
    
    func next() {
        // While between songs, currentIndex already points at the staged next track, so advance just starts playing it rather than skipping ahead.
        if isBetweenSongs {
            beginNextTrackFromBetweenSongs()
            return
        }
        if let idx = playableIndex(after: currentIndex) {
            play(index: idx)
        }
    }
    
    func previous() {
        if let idx = playableIndex(before: currentIndex) {
            play(index: idx)
        }
    }
    
    func seek(to relativeTime: TimeInterval) {
        if let track = currentTrack, track.source == .spotify {
            currentTime = relativeTime
            if isPlaying {
                playSpotifyTrack(track, overrideStartTime: track.startTime + relativeTime)
            }
            return
        }

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
        if track.source == .spotify {
            if currentTime > duration {
                currentTime = duration
            }
            return
        }

        if isPlaying {
            avPlayer?.rate = Float(track.speedMultiplier)
        }

        // Trimming or fading the song that's already loaded has to reach the mix that's
        // already playing, or the change wouldn't be heard until the next time it's cued.
        if let item = avPlayer?.currentItem {
            applyAudioMix(for: track, to: item)
        }
    }

    /// Diagnostic: logs where playback actually landed vs. where it was asked to, to catch a dropped seek without a debugger.
    func reportPlaybackPosition(requested: TimeInterval, label: String) {
        let trackID = currentTrack?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let track = self.currentTrack, track.id == trackID,
                  let position = self.avPlayer?.currentTime().seconds, position.isFinite
            else { return }

            print(String(
                format: "[%@] '%@': asked for %.3fs, playing at %.3fs (trim %.3f–%.3f, rate %.2f)",
                label, track.title, requested, position,
                track.startTime, track.resolvedEndTime, track.speedMultiplier
            ))
        }
    }

    /// True only if the loaded audio matches the track's current file — the compressor render at import can repoint a track mid-load.
    func hasLoadedAudio(forTrackID id: UUID) -> Bool {
        guard let track = currentTrack, track.id == id,
              let loaded = avPlayer?.currentItem?.asset as? AVURLAsset
        else { return false }

        return loaded.url == track.url
    }

    /// Plays only what's already loaded — unlike `togglePlayPause`, which falls back to the first playable song when nothing is loaded.
    func resumeLoadedTrack() {
        guard let avPlayer, avPlayer.currentItem != nil, let track = currentTrack else { return }

        isBetweenSongs = false
        avPlayer.play()
        avPlayer.rate = Float(track.speedMultiplier)
        isPlaying = true
    }

    /// Only re-cues while paused at the start — swapping mid-playback would cut the floor off, and rewinding a paused DJ would lose their place.
    private func recueIfLoadedAudioIsStale(index: Int) {
        guard tracks.indices.contains(index), currentIndex == index, !isPlaying,
              let avPlayer, avPlayer.currentItem != nil,
              !hasLoadedAudio(forTrackID: tracks[index].id)
        else { return }

        let position = avPlayer.currentTime().seconds
        guard position.isFinite, abs(position - tracks[index].startTime) < 0.05 else { return }

        prepareTrack(index: index, autoPlay: false)
    }

    /// AVPlayer holds an absolute position, not a bookmark, so a cued song stays at its old start point until re-cued here.
    /// A song already mid-playback is left alone unless the new region no longer contains it.
    func recueForTrimChange(previousStartTime: TimeInterval) {
        guard let avPlayer, let track = currentTrack, track.source == .local else { return }

        let position = avPlayer.currentTime().seconds
        guard position.isFinite else { return }

        // Parked on the old start is what "cued and waiting" looks like, and is the case that
        // has to follow the edit. Anywhere else is a position the DJ chose for themselves.
        let wasCuedAtStart = abs(position - previousStartTime) < 0.05
        let isOutsideNewRegion = position < track.startTime - 0.01 || position > track.playbackStopTime
        guard wasCuedAtStart || isOutsideNewRegion else { return }

        avPlayer.seek(
            to: CMTime(seconds: track.startTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        currentTime = 0
    }

    func reorderTrack(from draggedTrackID: UUID, before targetTrackID: UUID) -> Bool {
        guard draggedTrackID != targetTrackID,
              let fromIndex = tracks.firstIndex(where: { $0.id == draggedTrackID }),
              let toIndex = tracks.firstIndex(where: { $0.id == targetTrackID }) else {
            return false
        }

        let currentTrackID = currentIndex.flatMap { idx -> UUID? in
            guard tracks.indices.contains(idx) else { return nil }
            return tracks[idx].id
        }

        recordUndoSnapshot("Move Song")

        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        tracks.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: destination)

        if let currentTrackID {
            currentIndex = tracks.firstIndex(where: { $0.id == currentTrackID })
        }

        HapticFeedback.perform(.alignment)
        return true
    }
    
    func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        recordUndoSnapshot("Remove Song")
        
        if currentIndex == index {
            avPlayer?.pause()
            avPlayer = nil
            stopSpotifyProgressMonitor()
            isPlaying = false
            currentTime = 0
            duration = 0
            currentIndex = nil
        } else if let cur = currentIndex, cur > index {
            currentIndex = cur - 1
        }

        let removed = tracks.remove(at: index)
        // Removing a song also discards its library settings (trims, tempo, tags), so re-adding it starts clean rather than restoring them.
        forgetLibraryEntry(songHash: removed.songHash)
    }

    private func forgetLibraryEntry(songHash: String) {
        var library = loadLibrary()
        let remaining = library.tracks.filter { $0.songHash != songHash }
        guard remaining.count != library.tracks.count else { return }

        library.tracks = remaining
        writeLibrary(library)
    }

    private func applyPersistedSettings(_ persistedTrack: PersistedTrack, to track: inout Track) {
        track.title = persistedTrack.title
        track.artist = persistedTrack.artist
        track.danceStyles = Set(persistedTrack.danceStyles)
        track.customStyle = persistedTrack.customStyle
        track.isSkipped = persistedTrack.isSkipped ?? false
        track.startTime = persistedTrack.startTime
        track.endTime = persistedTrack.endTime
        track.tempoPercentage = persistedTrack.tempoPercentage
        track.manualBPM = persistedTrack.manualBPM ?? ""
        track.fadeInDuration = persistedTrack.fadeInDuration ?? 0
        track.fadeOutDuration = persistedTrack.fadeOutDuration ?? 0
        track.measuredLoudness = persistedTrack.measuredLoudness
        track.gainCorrectiondB = persistedTrack.gainCorrectiondB
        track.loudnessAnalysisVersion = persistedTrack.loudnessAnalysisVersion ?? 0
        track.hasCustomArtwork = persistedTrack.hasCustomArtwork ?? false

        if let source = persistedTrack.source {
            track.source = source
        }
        if let spotifyURI = persistedTrack.spotifyURI {
            track.spotifyURI = spotifyURI
        }
        if let spotifyExternalURL = persistedTrack.spotifyExternalURL.flatMap(URL.init(string:)) {
            track.spotifyExternalURL = spotifyExternalURL
            track.url = spotifyExternalURL
        }
        if let artworkData = persistedTrack.artworkData {
            track.artwork = NSImage(data: artworkData)
        }
    }

    private func spotifyImportInput(for persistedTrack: PersistedTrack) -> String? {
        if let spotifyURI = persistedTrack.spotifyURI, !spotifyURI.isEmpty {
            return spotifyURI
        }
        if let spotifyExternalURL = persistedTrack.spotifyExternalURL, !spotifyExternalURL.isEmpty {
            return spotifyExternalURL
        }
        if persistedTrack.songHash.hasPrefix("spotify:") {
            return String(persistedTrack.songHash.dropFirst("spotify:".count))
        }
        return nil
    }

    private func applyTaggedStyles(to track: inout Track) {
        guard let styleName = TaggedStyleRegistry.shared.styleName(for: track.songHash) else { return }
        print("Applied tagged style '\(styleName)' to \(track.songHash)")

        if let predefinedStyle = predefinedDanceStyles.first(where: {
            $0.caseInsensitiveCompare(styleName) == .orderedSame
        }) {
            track.danceStyles.insert(predefinedStyle)
        } else {
            track.danceStyles.insert("Other")
            if track.customStyle.isEmpty {
                track.customStyle = styleName
            }
        }
    }

    func importSpotify(input: String, kind: SpotifyImportKind, clientID: String) {
        isSpotifyImporting = true
        spotifyStatusMessage = nil
        beginImportActivity(message: kind == .playlist ? "Importing Spotify playlist..." : "Importing Spotify track...")

        Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.finishImportActivity()
                }
            }

            do {
                try await self.spotifyService.connect(clientID: clientID)
                switch kind {
                case .track:
                    let importedTrack = try await self.spotifyService.importTrack(from: input, clientID: clientID)
                    await MainActor.run {
                        self.appendSpotifyTracks([importedTrack])
                        self.isSpotifyImporting = false
                    }
                case .playlist:
                    let playlistTrackURIs = try await self.spotifyService.fetchPlaylistTrackURIs(from: input)
                    let importedTracks = try await self.spotifyService.importTracks(from: playlistTrackURIs, clientID: clientID)

                    await MainActor.run {
                        self.appendSpotifyTracks(importedTracks)
                        self.isSpotifyImporting = false
                        self.spotifyStatusMessage = "Imported \(importedTracks.count) Spotify track\(importedTracks.count == 1 ? "" : "s") from playlist."
                    }
                }
            } catch {
                await MainActor.run {
                    self.spotifyStatusMessage = error.localizedDescription
                    self.isSpotifyImporting = false
                }
            }
        }
    }

    func searchSpotifyTracks(query: String, clientID: String) {
        isSpotifySearching = true
        spotifyStatusMessage = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                let results = try await self.spotifyService.searchTracks(query: query, clientID: clientID)
                await MainActor.run {
                    self.spotifySearchResults = results
                    self.spotifyStatusMessage = results.isEmpty ? "No Spotify tracks found." : "Found \(results.count) Spotify track\(results.count == 1 ? "" : "s")."
                    self.isSpotifySearching = false
                }
            } catch {
                await MainActor.run {
                    self.spotifyStatusMessage = error.localizedDescription
                    self.isSpotifySearching = false
                }
            }
        }
    }

    func importSpotifyTrack(_ track: Track) {
        appendSpotifyTracks([track])
    }

    private func appendSpotifyTracks(_ importedTracks: [Track]) {
        let existingHashes = Set(tracks.map(\.songHash))
        let freshTracks = importedTracks
            .filter { !existingHashes.contains($0.songHash) }
            .map { importedTrack in
                var taggedTrack = importedTrack
                applyTaggedStyles(to: &taggedTrack)
                return taggedTrack
            }
        tracks.append(contentsOf: freshTracks)
        showThankYouScreen = false

        if currentIndex == nil, !tracks.isEmpty {
            prepareTrack(index: 0, autoPlay: false)
        }

        spotifyStatusMessage = "Imported \(freshTracks.count) Spotify track\(freshTracks.count == 1 ? "" : "s")."
    }

    private func playSpotifyTrack(_ track: Track, overrideStartTime: TimeInterval? = nil) {
        guard let uri = track.spotifyURI else {
            spotifyStatusMessage = "This Spotify track is missing its Spotify URI."
            return
        }

        stopSpotifyProgressMonitor()
        
        let absoluteStartTime = overrideStartTime ?? (track.startTime + self.currentTime)
        
        if overrideStartTime != nil {
            self.currentTime = max(0, absoluteStartTime - track.startTime)
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                let clientID = UserDefaults.standard.string(forKey: "spotifyClientID")
                try await self.spotifyService.startPlayback(uri: uri, clientID: clientID, position: absoluteStartTime)
                await MainActor.run {
                    self.spotifyStatusMessage = nil
                    self.startSpotifyProgressMonitor(for: track, absoluteStartTime: absoluteStartTime)
                }
            } catch {
                await MainActor.run {
                    self.spotifyStatusMessage = error.localizedDescription
                    self.isPlaying = false
                }
            }
        }
    }
    
    // MARK: - Spotify timestamp preview

    /// Spotify audio never reaches the app, so this is the only way to check whether a typed timestamp lands where it should.
    func previewSpotifyEdge(
        _ edge: SpotifyPreviewEdge,
        of track: Track,
        start: TimeInterval,
        end: TimeInterval
    ) {
        guard track.source == .spotify, let uri = track.spotifyURI else { return }

        let wasPreviewing = spotifyPreviewEdge
        stopSpotifyPreview()
        // Pressing the button that's already playing stops it, rather than restarting.
        guard wasPreviewing != edge else { return }

        // The set and the preview share one Spotify device, so auditioning over a running
        // song would take the music off the floor mid-phrase.
        if isPlaying { togglePlayPause() }

        let length = Self.spotifyPreviewLength
        let position = edge == .start ? start : max(start, end - length)

        spotifyPreviewEdge = edge
        spotifyPreviewTask = Task { [weak self] in
            guard let self else { return }
            let clientID = UserDefaults.standard.string(forKey: "spotifyClientID")

            do {
                try await self.spotifyService.startPlayback(
                    uri: uri,
                    clientID: clientID,
                    position: position
                )
            } catch {
                await MainActor.run {
                    self.spotifyStatusMessage = error.localizedDescription
                    self.spotifyPreviewEdge = nil
                }
                return
            }

            try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
            guard !Task.isCancelled else { return }

            try? await self.spotifyService.pausePlayback(clientID: clientID)
            await MainActor.run { self.spotifyPreviewEdge = nil }
        }
    }

    func stopSpotifyPreview() {
        spotifyPreviewTask?.cancel()
        spotifyPreviewTask = nil
        guard spotifyPreviewEdge != nil else { return }

        spotifyPreviewEdge = nil
        Task { [weak self] in
            let clientID = UserDefaults.standard.string(forKey: "spotifyClientID")
            try? await self?.spotifyService.pausePlayback(clientID: clientID)
        }
    }

    private func pauseSpotifyPlayback() {
        Task { [weak self] in
            guard let self else { return }

            do {
                let clientID = UserDefaults.standard.string(forKey: "spotifyClientID")
                try await self.spotifyService.pausePlayback(clientID: clientID)
            } catch {
                await MainActor.run {
                    self.spotifyStatusMessage = error.localizedDescription
                }
            }
        }
    }

    private func startSpotifyProgressMonitor(for track: Track, absoluteStartTime: TimeInterval) {
        stopSpotifyProgressMonitor()

        let trackID = track.id
        let trackURI = track.spotifyURI
        let startedAt = Date()
        let endTime = track.endTime ?? track.duration
        let relativeStartTime = max(0, absoluteStartTime - track.startTime)

        spotifyProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))

                await MainActor.run {
                    guard let self,
                          let currentTrack = self.currentTrack,
                          currentTrack.id == trackID,
                          self.isPlaying,
                          !self.isDraggingSlider
                    else { return }

                    let estimatedAbsoluteTime = absoluteStartTime + Date().timeIntervalSince(startedAt)
                    self.currentTime = min(currentTrack.effectiveDuration, max(relativeStartTime, estimatedAbsoluteTime - currentTrack.startTime))
                }

                let shouldCheckEnd = await MainActor.run { [weak self] in
                    guard let self,
                          let currentTrack = self.currentTrack,
                          currentTrack.id == trackID,
                          self.isPlaying
                    else { return false }

                    return currentTrack.startTime + self.currentTime >= endTime - 0.25
                }

                if shouldCheckEnd {
                    await self?.finishSpotifyTrackIfNeeded(trackID: trackID, trackURI: trackURI)
                    return
                }
            }
        }
    }

    private func stopSpotifyProgressMonitor() {
        spotifyProgressTask?.cancel()
        spotifyProgressTask = nil
    }

    private func finishSpotifyTrackIfNeeded(trackID: UUID, trackURI: String?) async {
        let clientID = UserDefaults.standard.string(forKey: "spotifyClientID")

        do {
            let state = try await spotifyService.playbackState(clientID: clientID)
            let isSameTrack = state?.item?.uri == trackURI

            if isSameTrack && state?.isPlaying == true {
                try await spotifyService.pausePlayback(clientID: clientID)
            }
        } catch {
            await MainActor.run {
                self.spotifyStatusMessage = error.localizedDescription
            }
        }

        await MainActor.run {
            guard let currentTrack = self.currentTrack, currentTrack.id == trackID else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.handleSongEnded()
        }
    }
    
    /// Only the derived gain is stale (loudness stays valid), so migrating is cheap arithmetic with no re-decode; bump loudnessAnalysisVersion to force a pass.
    func relevelLibraryGain() {
        // A pass works from a snapshot, so a project opened while one is running would be
        // missed. Re-run at the end instead of dropping the request.
        guard !isBatchProcessingLoudness else {
            isRelevelQueued = true
            return
        }

        // Header parse only, no decode. Runs whether or not anything needs re-measuring, so
        // the first play of every song already has its gain attached.
        warmAudioTrackIDCache()

        // Same reason it lives here: it has to run for songs that were imported long ago and
        // need no re-measuring, not only for ones arriving now.
        ensureSeekableAudio()

        let stale = tracks.filter {
            $0.source == .local && $0.loudnessAnalysisVersion < Self.loudnessAnalysisVersion
        }
        guard !stale.isEmpty else { return }

        let target = targetLoudnessLUFS
        var needsMeasuring: [Track] = []

        for track in stale {
            guard let loudness = track.measuredLoudness,
                  let correction = gainCorrection(forLoudness: loudness),
                  let index = tracks.firstIndex(where: { $0.id == track.id })
            else {
                needsMeasuring.append(track)
                continue
            }

            tracks[index].gainCorrectiondB = correction
            tracks[index].loudnessAnalysisVersion = Self.loudnessAnalysisVersion
            saveTrack(tracks[index])

            if currentIndex == index, let item = avPlayer?.currentItem {
                applyAudioMix(for: tracks[index], to: item)
            }
        }

        let rederived = stale.count - needsMeasuring.count
        guard !needsMeasuring.isEmpty else {
            print(String(format: "Re-derived %d gain tag(s) to %.1f LUFS — nothing to measure",
                         rederived, target))
            return
        }

        isBatchProcessingLoudness = true
        loudnessBatchProgress = 0.0

        // This already raises the import overlay, so it needs its own label rather than the
        // stale spinner left over from the project load that started it.
        beginImportActivity(message: "Levelling song volume…", totalCount: needsMeasuring.count)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            for (position, track) in needsMeasuring.enumerated() {
                let measurement = self.measureLoudness(of: track)

                DispatchQueue.main.async {
                    self.loudnessBatchProgress = Double(position + 1) / Double(needsMeasuring.count)
                    self.advanceImportProgress()

                    // Matched by id, not index — the queue can be reordered mid-pass.
                    guard let measurement,
                          let index = self.tracks.firstIndex(where: { $0.id == track.id })
                    else { return }

                    let neededCorrection = self.gainCorrection(
                        forLoudness: measurement.loudness,
                        peak: measurement.peak
                    )
                    self.tracks[index].measuredLoudness = measurement.loudness
                    self.tracks[index].gainCorrectiondB = neededCorrection
                    self.tracks[index].loudnessAnalysisVersion = Self.loudnessAnalysisVersion
                    self.saveTrack(self.tracks[index])

                    if self.currentIndex == index, let item = self.avPlayer?.currentItem {
                        self.applyAudioMix(for: self.tracks[index], to: item)
                    }
                }
            }

            DispatchQueue.main.async {
                self.isBatchProcessingLoudness = false
                self.loudnessBatchProgress = 0.0
                self.finishImportActivity()
                print(String(format: "Re-levelled %d track(s) to %.1f LUFS (%d re-derived without measuring)",
                             needsMeasuring.count, target, rederived))

                if self.isRelevelQueued {
                    self.isRelevelQueued = false
                    self.relevelLibraryGain()
                }
            }
        }
    }

    /// Usually no-ops — a cold launch has an empty queue — but covers a session that starts
    /// with songs already loaded.
    func relevelLibraryGainOnLaunch() {
        guard hasRunLaunchRelevel == false else { return }
        hasRunLaunchRelevel = true
        relevelLibraryGain()
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
            guard response == .OK else { return }
            self?.importAudioURLs(panel.urls)
        }
    }

    func openWorkbookImportPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "xlsx")!]
        panel.message = "Choose a Dancebreak DJ Workbook (CSV or XLSX)"
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadWorkbookImport(from: url)
    }

    /// Parses a workbook already chosen elsewhere (e.g. browsed in the new-project dialog)
    /// and hands it to the review pane.
    func loadWorkbookImport(from url: URL) {
        let rows = loadWorkbookRows(from: url)
        guard !rows.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "No songs found"
            alert.informativeText = "Couldn't find any recognizable song rows in that file. Check that it has \"Song Title\" and \"Artist\" columns."
            alert.runModal()
            return
        }

        // Defaults to the workbook file's own name when the DJ didn't type a project name; still editable before Confirm.
        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == "Dance Player Project" {
            projectName = sanitizeProjectName(url.deletingPathExtension().lastPathComponent)
        }

        pendingWorkbookImport = rows
    }

    private func importAudioURLs(
        _ urls: [URL],
        presetDanceStyles: Set<String>? = nil,
        runReplayGainOnAdd: Bool = false
    ) {
        let sortedURLs = sortedImportURLs(urls)

        guard !sortedURLs.isEmpty else { return }

        Task { [weak self] in
            guard let self else { return }

            await MainActor.run {
                self.beginImportActivity(message: "Importing audio files...", totalCount: sortedURLs.count)
            }

            for (index, url) in sortedURLs.enumerated() {
                await self.importAudioURL(
                    url,
                    presetDanceStyles: presetDanceStyles,
                    runReplayGainOnAdd: runReplayGainOnAdd,
                    shouldShowImportActivity: false
                )
                await MainActor.run {
                    self.importCompletedCount = min(self.importTotalCount, index + 1)
                }
            }

            await MainActor.run {
                self.finishImportActivity()
            }
        }
    }

    func importPopularEdit(_ edit: PopularEdit) {
        guard let url = popularEditResourceURL(for: edit) else {
            print("Popular edit resource not found: \(edit.resourceName).\(edit.fileExtension)")
            return
        }

        processAudioURL(url, presetDanceStyles: edit.danceStyles, runReplayGainOnAdd: true)

        guard let known = edit.knownBPM else { return }
        // Applied once the import lands, since the track doesn't exist yet at this point.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let index = self.tracks.firstIndex(where: {
                    self.popularEdit(for: $0)?.id == edit.id
                }) else { continue }
                if self.tracks[index].manualBPM.isEmpty {
                    self.tracks[index].manualBPM = String(known)
                    self.saveTrack(self.tracks[index])
                }
                return
            }
        }
    }

    // MARK: - Dance intros

    /// Spoken intros that ship with the app for the two dances that have one. Announced from the
    /// booth over the next-song screen, before the song itself starts.
    private static let danceIntros: [(style: String, resourceName: String, fileExtension: String)] = [
        (style: "Bohemian National Polka", resourceName: "BNP Intro", fileExtension: "m4a"),
        (style: "Romany Polka", resourceName: "Romany Polka Intro", fileExtension: "mp3"),
    ]

    /// The intro for a song, if it has one. Matched on dance style rather than on the recording,
    /// so a DJ's own copy of the polka gets the intro just as the shipped edit does.
    static func introURL(for track: Track) -> URL? {
        for intro in danceIntros where track.danceStyles.contains(intro.style) {
            if let url = Bundle.main.url(
                forResource: intro.resourceName,
                withExtension: intro.fileExtension,
                subdirectory: "audio files"
            ) ?? Bundle.main.url(forResource: intro.resourceName, withExtension: intro.fileExtension) {
                return url
            }
        }
        return nil
    }

    /// Played on its own player, deliberately outside the queue: the intro is not a song in the
    /// set, it doesn't advance anything, and it mustn't disturb what the transport has cued.
    func playIntro(for track: Track) {
        guard let url = Self.introURL(for: track) else { return }

        if isPlayingIntro {
            stopIntro()
            return
        }

        // An intro is being talked over otherwise: whatever the countdown was about to do, it
        // would do it during the announcement.
        pauseAutoplayCountdown()

        let item = AVPlayerItem(url: url)
        introPlayer = AVPlayer(playerItem: item)

        // Backstop for when the audible-content scan hasn't landed yet, or the file turns out
        // to have no meaningful silence tail at all.
        introFinishedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.stopIntro()
        }

        introPlayer?.play()
        isPlayingIntro = true
        scheduleIntroEarlyStop(url: url, item: item)
    }

    /// Recordings have a silent tail after the speech ends; stopping early avoids the button looking stuck for a few seconds.
    private func scheduleIntroEarlyStop(url: URL, item: AVPlayerItem) {
        if let cached = introAudibleDurationCache[url] {
            addIntroBoundary(at: cached, item: item)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let duration = Self.scanForAudibleDuration(of: url) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.introAudibleDurationCache[url] = duration
                // The DJ may have pressed Stop, or started a different intro, while this ran.
                guard self.introPlayer?.currentItem === item else { return }
                self.addIntroBoundary(at: duration, item: item)
            }
        }
    }

    /// A boundary observer rather than a wall-clock delay: it fires against the player's actual
    /// position, so it can't drift if playback stalls for buffering.
    private func addIntroBoundary(at duration: TimeInterval, item: AVPlayerItem) {
        Task { @MainActor [weak self] in
            guard let self, let itemDuration = try? await item.asset.load(.duration).seconds,
                  itemDuration.isFinite,
                  // Close enough to the file's own end that the natural end-of-file observer
                  // fires around the same moment anyway — nothing meaningful was trimmed.
                  duration < itemDuration - 0.2,
                  self.introPlayer?.currentItem === item
            else { return }

            let boundaryTime = NSValue(time: CMTime(seconds: duration, preferredTimescale: 600))
            self.introBoundaryObserver = self.introPlayer?.addBoundaryTimeObserver(
                forTimes: [boundaryTime],
                queue: .main
            ) { [weak self] in
                self?.stopIntro()
            }
        }
    }

    func stopIntro() {
        if let introFinishedObserver {
            NotificationCenter.default.removeObserver(introFinishedObserver)
        }
        introFinishedObserver = nil
        if let introBoundaryObserver {
            introPlayer?.removeTimeObserver(introBoundaryObserver)
        }
        introBoundaryObserver = nil
        introPlayer?.pause()
        introPlayer = nil
        isPlayingIntro = false
    }

    func importCursedSong(_ song: CursedSong) {
        guard let url = song.bundledURL else {
            presentError(
                title: "\(song.displayName) isn't installed",
                message: "Its audio file hasn't been added to the app yet. Drop "
                    + "\"\(song.resourceName).\(song.fileExtension)\" into the app's "
                    + "\"audio files\" folder and rebuild."
            )
            return
        }

        processAudioURL(url, presetDanceStyles: song.danceStyles, runReplayGainOnAdd: true)

        guard !song.customStyle.isEmpty || song.knownBPM != nil else { return }

        // The track doesn't exist yet at this point, so this waits for the import to land —
        // the same approach `importPopularEdit` uses for its published tempos.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let index = self.tracks.firstIndex(where: {
                    $0.url.standardizedFileURL == url.standardizedFileURL
                }) else { continue }

                if !song.customStyle.isEmpty {
                    self.tracks[index].customStyle = song.customStyle
                }
                if let known = song.knownBPM, self.tracks[index].manualBPM.isEmpty {
                    self.tracks[index].manualBPM = String(known)
                }
                self.saveTrack(self.tracks[index])
                return
            }
        }
    }

    private func popularEditResourceURL(for edit: PopularEdit) -> URL? {
        Bundle.main.url(forResource: edit.resourceName, withExtension: edit.fileExtension, subdirectory: "audio files")
            ?? Bundle.main.url(forResource: edit.resourceName, withExtension: edit.fileExtension)
    }
    
    func processAudioURL(
        _ url: URL,
        presetDanceStyles: Set<String>? = nil,
        runReplayGainOnAdd: Bool = false
    ) {
        Task {
            await self.importAudioURL(
                url,
                presetDanceStyles: presetDanceStyles,
                runReplayGainOnAdd: runReplayGainOnAdd,
                shouldShowImportActivity: true
            )
        }
    }

    // MARK: - Dancebreak DJ Workbook Import
    // These async variants are awaited directly, unlike the fire-and-forget import above, so the workbook importer can proceed one song at a time.

    func importWorkbookPopularEdit(
        _ edit: PopularEdit,
        title: String,
        artist: String,
        danceStyles: Set<String>,
        customStyle: String,
        manualBPM: String
    ) async {
        guard let url = popularEditResourceURL(for: edit) else {
            print("Popular edit resource not found: \(edit.resourceName).\(edit.fileExtension)")
            return
        }
        // The workbook's title/style/BPM take priority over the bundled file's own tags or a stale cache entry.
        let hash = hashAudioFile(url)
        await importAudioURL(url, presetDanceStyles: danceStyles, runReplayGainOnAdd: true, shouldShowImportActivity: true)

        await MainActor.run {
            guard let idx = self.tracks.firstIndex(where: { $0.songHash == hash }) else { return }
            self.tracks[idx].title = title
            self.tracks[idx].artist = artist
            self.tracks[idx].danceStyles = danceStyles
            self.tracks[idx].customStyle = customStyle
            self.tracks[idx].manualBPM = manualBPM
            self.saveTrack(self.tracks[idx])
        }
    }

    func importWorkbookLocalFile(
        url: URL,
        title: String,
        artist: String,
        danceStyles: Set<String>,
        customStyle: String,
        manualBPM: String
    ) async {
        // The file's own tags usually give a better title/artist than a hand-typed workbook; styles/BPM still come from the sheet.
        // Read separately from import, since importAudioURL substitutes defaults that would no longer look blank here.
        let embedded = await embeddedTitleAndArtist(for: url)
        let hash = hashAudioFile(url)
        await importAudioURL(url, presetDanceStyles: danceStyles, runReplayGainOnAdd: false, shouldShowImportActivity: true)

        await MainActor.run {
            guard let idx = self.tracks.firstIndex(where: { $0.songHash == hash }) else { return }
            self.tracks[idx].title = embedded.title ?? title
            self.tracks[idx].artist = embedded.artist ?? artist
            self.tracks[idx].danceStyles = danceStyles
            self.tracks[idx].customStyle = customStyle
            self.tracks[idx].manualBPM = manualBPM
            self.saveTrack(self.tracks[idx])
        }
    }

    /// Title/artist as the file actually declares them, or nil — unlike `importAudioURL`, which substitutes defaults when tags are missing.
    private func embeddedTitleAndArtist(for url: URL) async -> (title: String?, artist: String?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let items = try? await AVURLAsset(url: url).load(.commonMetadata) else {
            return (nil, nil)
        }

        var title: String?
        var artist: String?

        for item in items {
            guard let key = item.commonKey,
                  let value = try? await item.load(.stringValue) else { continue }

            // A tag present but blank is no more use than a missing one.
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            switch key {
            case .commonKeyTitle: title = trimmed
            case .commonKeyArtist: artist = trimmed
            default: break
            }
        }

        return (title, artist)
    }

    /// Searches Spotify for `title artist` and returns candidates for the DJ to choose from; requires a Spotify Client ID and completed sign-in.
    func searchWorkbookSpotifyTracks(title: String, artist: String, clientID: String) async -> [Track] {
        do {
            try await spotifyService.connect(clientID: clientID)
            let query = artist.isEmpty || artist == "Unknown Artist" ? title : "\(title) \(artist)"
            return try await spotifyService.searchTracks(query: query, clientID: clientID)
        } catch {
            return []
        }
    }

    /// Imports the specific search result the DJ picked, applying the workbook row's
    /// dance styles / custom style / BPM overrides.
    func importWorkbookSpotifyMatch(
        _ track: Track,
        title: String,
        artist: String,
        danceStyles: Set<String>,
        customStyle: String,
        manualBPM: String
    ) async {
        var matched = track
        // Spotify's title/artist win over the workbook's; the fallback here is rarely needed since Spotify always returns both.
        matched.title = Self.firstNonEmpty(track.title, title)
        matched.artist = Self.firstNonEmpty(track.artist, artist)
        matched.danceStyles = danceStyles
        matched.customStyle = customStyle
        matched.manualBPM = manualBPM

        await MainActor.run {
            self.appendSpotifyTracks([matched])
        }
    }

    private static func firstNonEmpty(_ preferred: String, _ fallback: String) -> String {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Resolves a pasted Spotify track URL/URI directly instead of searching by text —
    /// used as the Confirm-time fallback for a row with no approved match.
    func resolveWorkbookSpotifyURL(_ input: String, clientID: String) async -> Track? {
        do {
            try await spotifyService.connect(clientID: clientID)
            return try await spotifyService.importTrack(from: input, clientID: clientID)
        } catch {
            return nil
        }
    }

    private func sortedImportURLs(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let leftKey = importSortKey(for: lhs)
            let rightKey = importSortKey(for: rhs)

            if leftKey.group != rightKey.group {
                return leftKey.group < rightKey.group
            }

            if leftKey.number != rightKey.number {
                return leftKey.number < rightKey.number
            }

            return leftKey.name.localizedStandardCompare(rightKey.name) == .orderedAscending
        }
    }

    private func importSortKey(for url: URL) -> (group: Int, number: Int, name: String) {
        let name = url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = name.range(of: #"^\d+"#, options: .regularExpression),
           let number = Int(name[match]),
           number > 0 {
            return (0, number, name.lowercased())
        }

        return (1, Int.max, name.lowercased())
    }

    private func importAudioURL(
        _ url: URL,
        presetDanceStyles: Set<String>? = nil,
        runReplayGainOnAdd: Bool = false,
        shouldShowImportActivity: Bool
    ) async {
        let accessSecure = url.startAccessingSecurityScopedResource()
        let asset = AVURLAsset(url: url)

        if shouldShowImportActivity {
            await MainActor.run {
                self.beginImportActivity(message: "Importing audio files...")
            }
        }

        defer {
            if shouldShowImportActivity {
                Task { @MainActor in
                    self.finishImportActivity()
                }
            }
        }

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
                    if let keyString = item.key as? String,
                       (keyString.lowercased().contains("dance style") || keyString == "TXXX"),
                       let val = try await item.load(.stringValue) {
                        danceStyleParsed = val
                            .replacingOccurrences(of: "Dance Style\u{0}", with: "", options: [.caseInsensitive])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } catch {
            print("Metadata extraction error: \(error.localizedDescription)")
        }

        let hash = hashAudioFile(url)

        // Everything below is disk/CPU work (JSON decode, audio file copy, artwork write) that
        // doesn't touch @Published state — keep it off the main actor so imports don't stall the UI.
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

        if let presetDanceStyles {
            matchedStyles.formUnion(presetDanceStyles)
        }

        var newTrack = Track(
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
            loudnessAnalysisVersion: saved?.loudnessAnalysisVersion ?? 0,
            startTime: startTime,
            endTime: endTime,
            tempoPercentage: tempoPercentage,
            manualBPM: saved?.manualBPM ?? ""
        )

        applyTaggedStyles(to: &newTrack)
        materializeLocalTrackAssetsIfNeeded(
            &newTrack,
            sourceURL: url,
            artwork: artwork
        )

        await MainActor.run { [weak self] in
            guard let self = self else { return }

            self.tracks.append(newTrack)
            self.showThankYouScreen = false
            let trackIndex = self.tracks.count - 1

            if self.currentIndex == nil {
                self.prepareTrack(index: self.firstPlayableIndex ?? trackIndex, autoPlay: false)
            }

            if runReplayGainOnAdd {
                self.calculateLoudness(forTrackAt: trackIndex)
            }

            // Trigger background trailing silence analysis after the track is in the queue.
            print("Starting trailing silence trim analysis for: \(title)")
            self.trimTrailingSilence(forTrackAt: trackIndex, releaseSecurityScope: accessSecure ? url : nil)
        }
    }

    // MARK: - Core Audio Trimming Engine
    /// Same -70dB silence gate as `trimTrailingSilence`, extracted so dance intros can reuse it; runs off the main actor.
    nonisolated private static func scanForAudibleDuration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = UInt32(file.length)
        guard frameCount > 0 else { return nil }

        let bufferSize = min(frameCount, 44100 * 2)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else { return nil }

        var currentFrameOffset = Int64(frameCount)
        var silenceEndFrame = Int64(frameCount)
        let silenceThreshold: Float = 0.000316 // Linear amplitude ~ -70dB

        while currentFrameOffset > 0 {
            let readLength = min(Int64(bufferSize), currentFrameOffset)
            currentFrameOffset -= readLength
            file.framePosition = currentFrameOffset

            guard (try? file.read(into: buffer, frameCount: UInt32(readLength))) != nil,
                  let channels = buffer.floatChannelData
            else { break }

            var foundAudio = false
            for frame in (0..<Int(readLength)).reversed() {
                if abs(channels[0][frame]) > silenceThreshold {
                    silenceEndFrame = currentFrameOffset + Int64(frame)
                    foundAudio = true
                    break
                }
            }
            if foundAudio { break }
        }

        return Double(silenceEndFrame) / format.sampleRate
    }

    private func trimTrailingSilence(forTrackAt index: Int, releaseSecurityScope scopedURL: URL? = nil) {
        guard tracks.indices.contains(index) else {
            scopedURL?.stopAccessingSecurityScopedResource()
            return
        }
        let track = tracks[index]
        let sourceURL = track.url
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                scopedURL?.stopAccessingSecurityScopedResource()
                return
            }
            
            do {
                let file = try AVAudioFile(forReading: sourceURL)
                let format = file.processingFormat
                let frameCount = UInt32(file.length)
                
                // Read chunks backward to find where the audio actually drops below -70dB
                let bufferSize = min(frameCount, 44100 * 2) // 2-second chunks
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                    scopedURL?.stopAccessingSecurityScopedResource()
                    return
                }

                var currentFrameOffset = Int64(frameCount)
                var silenceEndFrame = Int64(frameCount)
                let silenceThreshold: Float = 0.000316 // Linear amplitude ~ -70dB
                
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
                    print("Trimming detected! Marking trailing \(totalDuration - calculatedDuration)s of silence as trimmed (metadata only).")
                    scopedURL?.stopAccessingSecurityScopedResource()
                    self.applyDetectedTrailingSilenceTrim(endTrimTime: calculatedDuration, trackIndex: index)
                } else {
                    print("No meaningful trailing silence detected.")
                    scopedURL?.stopAccessingSecurityScopedResource()
                    DispatchQueue.main.async {
                        self.calculateLoudness(forTrackAt: index)
                    }
                }
                
            } catch {
                scopedURL?.stopAccessingSecurityScopedResource()
                print("Failed to scan track for trailing silence: \(error.localizedDescription)")
            }
        }
    }

    /// Records the auto-detected trailing-silence boundary as `endTime` metadata
    private func applyDetectedTrailingSilenceTrim(endTrimTime: TimeInterval, trackIndex: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.tracks.indices.contains(trackIndex) else { return }

            // Don't clobber a trim the user may have already set manually in the time
            // it took the background scan to finish.
            if self.tracks[trackIndex].endTime == nil {
                self.tracks[trackIndex].endTime = endTrimTime
            }

            self.saveTrack(self.tracks[trackIndex])
            self.scheduleProjectAutosave()

            if self.currentIndex == trackIndex {
                self.synchronizeActiveTrackSettings()
            }

            print("Trailing silence trim applied as metadata; original file left untouched.")
            self.calculateLoudness(forTrackAt: trackIndex)
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
            window.isReleasedWhenClosed = false
            window.delegate = displayWindowObserver

            displayWindowController = NSWindowController(window: window)
        }
        displayWindowController?.showWindow(nil)
        isDisplayWindowOpen = true
    }

    func closeDisplayWindow() {
        displayWindowController?.close()
        isDisplayWindowOpen = false
    }

    /// Keeps `isDisplayWindowOpen` honest when the DJ closes the window with its own button
    /// rather than the View menu.
    private lazy var displayWindowObserver: DisplayWindowObserver = {
        DisplayWindowObserver { [weak self] in self?.isDisplayWindowOpen = false }
    }()

    /// A window rather than a sheet, so the DJ can keep it open beside the queue while working
    /// through a set — and so its prefetching survives closing Advanced Settings.
    func openCoverArtWindow() {
        if coverArtWindowController == nil {
            let hostingController = NSHostingController(rootView: CoverArtPickerView(player: self))

            let window = NSWindow(
                contentRect: NSRect(x: 140, y: 140, width: 620, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Cover Art"
            window.contentViewController = hostingController
            window.isReleasedWhenClosed = false
            window.delegate = coverArtWindowObserver

            coverArtWindowController = NSWindowController(window: window)
        }
        coverArtWindowController?.showWindow(nil)
        isCoverArtWindowOpen = true
    }

    func closeCoverArtWindow() {
        coverArtWindowController?.close()
        isCoverArtWindowOpen = false
    }

    private lazy var coverArtWindowObserver: DisplayWindowObserver = {
        DisplayWindowObserver { [weak self] in self?.isCoverArtWindowOpen = false }
    }()

    // MARK: - Timing editor

    /// Presented as a sheet over the queue rather than a separate window; local files only, since Spotify audio never reaches the app.
    func openTimingEditor(for trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }), track.source == .local else { return }
        timingEditorTrackID = trackID
    }

    func closeTimingEditor() {
        timingEditorTrackID = nil
    }

    var isTimingEditorPresented: Bool { timingEditorTrackID != nil }

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
                source: track.source,
                spotifyURI: track.spotifyURI,
                spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                manualBPM: track.manualBPM,
                fadeInDuration: track.fadeInDuration,
                fadeOutDuration: track.fadeOutDuration,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
                loudnessAnalysisVersion: track.loudnessAnalysisVersion,
                hasCustomArtwork: track.hasCustomArtwork,
                artworkData: track.persistableArtworkData
            )

        } else {

            library.tracks.append(
                PersistedTrack(
                    songHash: track.songHash,
                    source: track.source,
                    spotifyURI: track.spotifyURI,
                    spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                    title: track.title,
                    artist: track.artist,
                    danceStyles: Array(track.danceStyles),
                    customStyle: track.customStyle,
                    startTime: track.startTime,
                    endTime: track.endTime,
                    tempoPercentage: track.tempoPercentage,
                    manualBPM: track.manualBPM,
                    fadeInDuration: track.fadeInDuration,
                    fadeOutDuration: track.fadeOutDuration,
                        measuredLoudness: track.measuredLoudness,
                    gainCorrectiondB: track.gainCorrectiondB,
                    loudnessAnalysisVersion: track.loudnessAnalysisVersion,
                    hasCustomArtwork: track.hasCustomArtwork,
                    artworkData: track.persistableArtworkData
                )
            )
        }

        writeLibrary(library)
    }

    func exportProjectPackage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.message = "Choose a destination folder for the exported project package."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationDirectoryURL = panel.url else { return }

        do {
            let projectFolderURL = try exportProjectPackage(
                toProjectFolder: destinationDirectoryURL,
                projectName: safeProjectName
            )
            print("Exported project package to \(projectFolderURL.path)")
        } catch {
            print("Failed exporting project package: \(error.localizedDescription)")
        }
    }

    func importProjectPackage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = defaultPanelDirectoryURL
        panel.message = "Choose an exported project folder."
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let projectFolderURL = panel.url else { return }

        let shouldClearExistingTracks: Bool
        if !tracks.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Import Project"
            alert.informativeText = "Do you want to clear the current play queue before importing this project?"
            alert.addButton(withTitle: "Clear Existing")
            alert.addButton(withTitle: "Keep Existing")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                shouldClearExistingTracks = true
            case .alertSecondButtonReturn:
                shouldClearExistingTracks = false
            default:
                return
            }
        } else {
            shouldClearExistingTracks = true
        }

        Task { [weak self] in
            // Progress reporting lives inside importProjectPackage, which knows the count.
            await self?.importProjectPackage(
                from: projectFolderURL,
                clearExistingTracks: shouldClearExistingTracks
            )
        }
    }

    func createNewProject(named name: String, autosaveParentURL: URL?) {
        let sanitizedName = sanitizeProjectName(name)
        projectName = sanitizedName
        projectAutosaveParentURL = autosaveParentURL
        projectFolderURL = nil
        autosaveEnabled = autosaveParentURL != nil
        hasLoadedProject = true
        showThankYouScreen = false
        tracks.removeAll()
        currentIndex = nil
        lastTrack = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        isBetweenSongs = false
        selectedTrackForEditing = nil
        spotifySearchResults = []
        spotifyStatusMessage = nil
        showTempo = false
        autoplayEnabled = false
        autoplayDelaySeconds = 10.0
        pauseAutoplayCountdown()
        persistTracksToLibrary([])

        // Created eagerly so materializeLocalTrackAssetsIfNeeded works for the first track add, before the first autosave fires.
        if let root = projectRootFolderURL {
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("files", isDirectory: true),
                withIntermediateDirectories: true
            )
            try? FileManager.default.createDirectory(
                at: root.appendingPathComponent("artwork", isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        saveCurrentProjectPackage()
    }

    /// Creates a project from values the new-project dialog already collected — the folder
    /// and workbook were browsed there, so nothing needs to be prompted for here.
    func createProject(named name: String, autosaveFolder: URL?, workbookURL: URL?) {
        createNewProject(named: sanitizeProjectName(name), autosaveParentURL: nil)

        // Saving produces a single .dbdj in the chosen folder rather than a project folder.
        if let autosaveFolder {
            adoptProjectFile(named: name, savingInto: autosaveFolder)
            // Write it straight away so the file is visible before the first edit.
            saveCurrentProjectPackage()
        }

        if let workbookURL {
            loadWorkbookImport(from: workbookURL)
        }
    }

    func beginNewProjectFlow(named name: String, autosaveRequested: Bool) {
        let sanitizedName = sanitizeProjectName(name)

        guard autosaveRequested else {
            createNewProject(
                named: sanitizedName,
                autosaveParentURL: nil
            )
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.message = "Choose where the project folder should live."
        panel.prompt = "Choose"

        panel.begin { [weak self] response in
            guard response == .OK, let folderURL = panel.url else { return }
            DispatchQueue.main.async {
                self?.createNewProject(
                    named: sanitizedName,
                    autosaveParentURL: folderURL
                )
            }
        }
    }

    /// Starts a fresh project shell, then opens the Workbook import picker.
    func beginWorkbookImportFlow(named name: String, autosaveRequested: Bool) {
        let sanitizedName = sanitizeProjectName(name)

        guard autosaveRequested else {
            createNewProject(named: sanitizedName, autosaveParentURL: nil)
            openWorkbookImportPicker()
            return
        }

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.message = "Choose where the project folder should live."
        panel.prompt = "Choose"

        panel.begin { [weak self] response in
            guard response == .OK, let folderURL = panel.url else { return }
            DispatchQueue.main.async {
                self?.createNewProject(named: sanitizedName, autosaveParentURL: folderURL)
                self?.openWorkbookImportPicker()
            }
        }
    }

    func beginImportProjectFlow(named name: String, autosaveRequested: Bool) {
        let sanitizedName = sanitizeProjectName(name)
        let projectPanel = NSOpenPanel()
        projectPanel.allowsMultipleSelection = false
        projectPanel.canChooseDirectories = true
        projectPanel.canChooseFiles = true
        projectPanel.allowedContentTypes = [Self.projectFileType]
        projectPanel.directoryURL = defaultPanelDirectoryURL
        projectPanel.message = "Choose a .dbdj project file or an exported project folder."
        projectPanel.prompt = "Open"

        projectPanel.begin { [weak self] response in
            guard let self, response == .OK, let projectFolderURL = projectPanel.url else { return }

            // A single-file project takes the .dbdj path instead; it unpacks to a temporary
            // folder rather than being loaded in place.
            let isDirectory = (try? projectFolderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDirectory != true {
                DispatchQueue.main.async { self.openProjectFile(at: projectFolderURL) }
                return
            }

            let shouldClearExistingTracks: Bool
            if !self.tracks.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Import Project"
                alert.informativeText = "Do you want to clear the current play queue before importing this project?"
                alert.addButton(withTitle: "Clear Existing")
                alert.addButton(withTitle: "Keep Existing")
                alert.addButton(withTitle: "Cancel")

                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    shouldClearExistingTracks = true
                case .alertSecondButtonReturn:
                    shouldClearExistingTracks = false
                default:
                    return
                }
            } else {
                shouldClearExistingTracks = true
            }

            DispatchQueue.main.async {
                self.projectName = projectFolderURL.lastPathComponent.isEmpty ? sanitizedName : projectFolderURL.lastPathComponent
                self.projectAutosaveParentURL = nil
                self.projectFolderURL = projectFolderURL
                self.autosaveEnabled = true
                self.hasLoadedProject = true

                Task {
                    await self.importProjectPackage(
                        from: projectFolderURL,
                        clearExistingTracks: shouldClearExistingTracks
                    )
                }
            }
        }
    }

    // MARK: - Single-file (.dbdj) projects

    /// A `.dbdj` is just a zip of the same folder layout `exportProjectPackage` writes, so a
    /// project can be handed around as one file instead of a folder of loose parts.
    static let projectFileExtension = "dbdj"

    /// Resolved by extension rather than `UTType(exportedAs:)` so it still works if the
    /// declaration in Info.plist hasn't been registered by Launch Services yet.
    static var projectFileType: UTType {
        UTType(filenameExtension: projectFileExtension) ?? .zip
    }

    func exportProjectFile() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.nameFieldStringValue = "\(safeProjectName).\(Self.projectFileExtension)"
        panel.allowedContentTypes = [Self.projectFileType]
        panel.message = "Save this project as a single .dbdj file."
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        let fileManager = FileManager.default
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("dbdj-export-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: stagingURL) }

            let projectFolderURL = try exportProjectPackage(
                toProjectFolder: stagingURL,
                projectName: safeProjectName
            )
            try ZipArchive.zip(contentsOf: projectFolderURL, to: destinationURL)
            print("Exported project file to \(destinationURL.path)")
        } catch {
            presentError(title: "Couldn't Export Project", message: error.localizedDescription)
        }
    }

    /// Unpacks a `.dbdj` and loads it. Further edits autosave straight back into the same
    /// file, so the DJ never has to think about re-exporting.
    func openProjectFile(at fileURL: URL) {
        let name = sanitizeProjectName(fileURL.deletingPathExtension().lastPathComponent)
        let unpackedURL = freshWorkingFolderURL(named: name)

        do {
            try ZipArchive.unzip(fileURL, to: unpackedURL)
        } catch {
            presentError(title: "Couldn't Open Project", message: error.localizedDescription)
            return
        }

        let shouldClearExistingTracks: Bool
        if !tracks.isEmpty {
            switch clearQueueBeforeImportChoice() {
            case .clear: shouldClearExistingTracks = true
            case .keep: shouldClearExistingTracks = false
            case .cancel: return
            }
        } else {
            shouldClearExistingTracks = true
        }

        projectName = name
        projectAutosaveParentURL = nil
        projectFolderURL = nil
        projectFileURL = fileURL
        projectWorkingFolderURL = unpackedURL
        autosaveEnabled = true
        hasLoadedProject = true
        ProjectLocations.noteRecentProject(fileURL)

        Task {
            await importProjectPackage(from: unpackedURL, clearExistingTracks: shouldClearExistingTracks)
        }
    }

    private enum ClearQueueChoice { case clear, keep, cancel }

    private func clearQueueBeforeImportChoice() -> ClearQueueChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open Project"
        alert.informativeText = "Do you want to clear the current play queue before opening this project?"
        alert.addButton(withTitle: "Clear Existing")
        alert.addButton(withTitle: "Keep Existing")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn: return .clear
        case .alertSecondButtonReturn: return .keep
        default: return .cancel
        }
    }

    /// Asks for a Spotify client ID inline. Returns the key, or nil if the DJ chooses to
    /// carry on without the Spotify songs.
    @MainActor
    private func promptForSpotifyKey(message: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Spotify API Key Needed"
        alert.informativeText = message

        let field = NSTextField(string: spotifyClientID)
        field.placeholderString = "Spotify client ID"
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Skip Spotify Songs")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return nil }
        spotifyClientID = entered
        return entered
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    func saveProjectAs() {
        let alert = NSAlert()
        alert.messageText = "Save Project As"
        alert.informativeText = "Choose a new project name."
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "Project Name"
        nameField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = sanitizeProjectName(typedName.isEmpty ? "\(safeProjectName) copy" : typedName)

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.nameFieldStringValue = "\(newName).\(Self.projectFileExtension)"
        panel.allowedContentTypes = [Self.projectFileType]
        panel.message = "Choose where the project file should be saved."
        panel.prompt = "Save"

        panel.begin { [weak self] response in
            guard let self, response == .OK, let destinationURL = panel.url else { return }
            DispatchQueue.main.async {
                self.projectName = newName
                self.projectAutosaveParentURL = nil
                self.projectFolderURL = nil
                self.projectFileURL = destinationURL
                self.projectWorkingFolderURL = self.freshWorkingFolderURL(named: newName)
                self.autosaveEnabled = true
                self.hasLoadedProject = true
                ProjectLocations.noteRecentProject(destinationURL)
                self.saveCurrentProjectPackage()
            }
        }
    }
    
    private func exportProjectPackage(
        toProjectFolder destinationDirectoryURL: URL,
        projectName: String,
        overwriteExisting: Bool = false
    ) throws -> URL {
        let fileManager = FileManager.default
        let sanitizedProjectName = sanitizeProjectName(projectName)
        let projectFolderURL = overwriteExisting
            ? destinationDirectoryURL
            : uniqueProjectPackageFolderURL(
                in: destinationDirectoryURL,
                projectName: sanitizedProjectName
            )
        let filesFolderURL = projectFolderURL.appendingPathComponent("files", isDirectory: true)
        let artworkFolderURL = projectFolderURL.appendingPathComponent("artwork", isDirectory: true)

        try fileManager.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: artworkFolderURL, withIntermediateDirectories: true)

        var exportedTracks: [ProjectPackageTrack] = []

        for track in tracks {
            var localFileName: String? = nil
            var bundledFileName: String? = nil
            var artworkFileName: String? = nil

            // Popular Edits play from a file inside the app bundle, which every install
            // already has — record the name and skip the copy entirely.
            if track.source == .local, track.url.isFileURL, let shippedName = self.bundledFileName(for: track) {
                bundledFileName = shippedName
                // Drop a copy left behind by a save from before this optimization, which
                // would otherwise keep bloating the file.
                removeStaleLocalAudioCopies(
                    songHash: track.songHash,
                    keepingFileName: "",
                    in: filesFolderURL
                )
            } else if track.source == .local, track.url.isFileURL {
                localFileName = projectPackageFileName(for: track)
                let destinationURL = filesFolderURL.appendingPathComponent(localFileName!)

                // Safety net: drop any stale copy of this track under a different
                // file extension, so we never keep two on-disk copies for one song.
                removeStaleLocalAudioCopies(
                    songHash: track.songHash,
                    keepingFileName: localFileName!,
                    in: filesFolderURL
                )

                if track.url.standardizedFileURL != destinationURL.standardizedFileURL {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: track.url, to: destinationURL)
                }
            }


            // Only DJ-chosen art is stored. Anything that came from the audio file's own
            // tags is re-read on import, so it isn't duplicated into the project.
            let safeHash = track.songHash.replacingOccurrences(of: ":", with: "_")
            if track.source == .local, let artworkData = track.persistableArtworkData {
                artworkFileName = "\(safeHash).jpg"
                let artworkURL = artworkFolderURL.appendingPathComponent(artworkFileName!)
                // Overwrite whatever art was there before, including a PNG written by an
                // older version of the app.
                for stale in ["\(safeHash).png", artworkFileName!] {
                    let staleURL = artworkFolderURL.appendingPathComponent(stale)
                    if fileManager.fileExists(atPath: staleURL.path) {
                        try fileManager.removeItem(at: staleURL)
                    }
                }
                try artworkData.write(to: artworkURL, options: .atomic)
            } else {
                for stale in ["\(safeHash).png", "\(safeHash).jpg"] {
                    let staleURL = artworkFolderURL.appendingPathComponent(stale)
                    if fileManager.fileExists(atPath: staleURL.path) {
                        try fileManager.removeItem(at: staleURL)
                    }
                }
            }

            exportedTracks.append(
                ProjectPackageTrack(
                    from: track,
                    localFileName: localFileName,
                    bundledFileName: bundledFileName,
                    artworkFileName: artworkFileName
                )
            )
        }

        let package = ProjectPackageExport(
            projectName: sanitizedProjectName,
            tracks: exportedTracks,
            showTempo: showTempo,
            autoplayEnabled: autoplayEnabled,
            autoplayDelaySeconds: autoplayDelaySeconds
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(package)
        try data.write(to: projectFolderURL.appendingPathComponent("project.json"), options: .atomic)

        let orderExport = ProjectPackageOrderExport(songHashes: exportedTracks.map { $0.songHash })
        let orderData = try encoder.encode(orderExport)
        try orderData.write(to: projectFolderURL.appendingPathComponent("song_order.json"), options: .atomic)

        return projectFolderURL
    }

    private func importProjectPackage(
        from projectFolderURL: URL,
        clearExistingTracks: Bool
    ) async {
        // Owned here rather than by each caller, so opening a .dbdj gets the same progress
        // reporting as importing a project folder.
        await MainActor.run { self.beginImportActivity(message: "Opening project…") }
        defer { Task { @MainActor in self.finishImportActivity() } }

        do {
            let package = try loadProjectPackage(from: projectFolderURL)

            // Song count is known now, so the spinner can become a real bar.
            await MainActor.run {
                self.setImportTotal(package.tracks.count, message: "Importing songs…")
            }

            let filesFolderURL = projectFolderURL.appendingPathComponent("files", isDirectory: true)
            let artworkFolderURL = projectFolderURL.appendingPathComponent("artwork", isDirectory: true)
            let existingTracks = await MainActor.run { self.tracks }
            let previousActiveSongHash = await MainActor.run { self.currentTrack?.songHash }

            let spotifyTrackCount = package.tracks.filter { $0.source == .spotify }.count
            var clientID = await MainActor.run {
                self.spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            var includeSpotify = spotifyTrackCount > 0

            // This project needs Spotify. Ask for a key rather than failing silently — the
            // old behaviour aborted the whole import and left an empty project behind.
            if includeSpotify, clientID.isEmpty {
                let songWord = spotifyTrackCount == 1 ? "song" : "songs"
                if let entered = await MainActor.run(body: {
                    self.promptForSpotifyKey(
                        message: "This project has \(spotifyTrackCount) Spotify \(songWord). "
                            + "Enter your Spotify client ID to load them."
                    )
                }) {
                    clientID = entered
                } else {
                    includeSpotify = false
                }
            }

            if includeSpotify {
                do {
                    try await spotifyService.connect(clientID: clientID)
                    await MainActor.run { self.spotifyStatusMessage = "Spotify connection confirmed." }
                } catch {
                    // One chance to correct a wrong key before giving up on the Spotify songs.
                    if let retryID = await MainActor.run(body: {
                        self.promptForSpotifyKey(
                            message: "Couldn't connect to Spotify with that key "
                                + "(\(error.localizedDescription)). Check it and try again."
                        )
                    }) {
                        clientID = retryID
                        do {
                            try await spotifyService.connect(clientID: clientID)
                            await MainActor.run { self.spotifyStatusMessage = "Spotify connection confirmed." }
                        } catch {
                            includeSpotify = false
                        }
                    } else {
                        includeSpotify = false
                    }
                }
            }

            if spotifyTrackCount > 0, !includeSpotify {
                let songWord = spotifyTrackCount == 1 ? "song" : "songs"
                await MainActor.run {
                    self.spotifyStatusMessage =
                        "\(spotifyTrackCount) Spotify \(songWord) skipped — no working API key."
                    self.presentError(
                        title: "Spotify Songs Not Loaded",
                        message: "\(spotifyTrackCount) \(songWord) in this project come from Spotify and "
                            + "need an API key. The rest of the project has been opened. Add a key under "
                            + "Settings ▸ Set Spotify API Key, then open the project again to load them."
                    )
                }
            }

            let importedTracks = try await buildTracks(
                from: package,
                filesFolderURL: filesFolderURL,
                artworkFolderURL: artworkFolderURL,
                clientID: clientID,
                includeSpotify: includeSpotify
            )

            // Re-order the imported tracks to match song_order.json.
            // This is what actually restores the playlist order on import.
            let songOrder = loadSongOrder(from: projectFolderURL, fallbackTracks: package.tracks)
            let orderedImportedTracks: [Track] = {
                var orderMap: [String: Int] = [:]
                for (i, hash) in songOrder.enumerated() { orderMap[hash] = i }
                return importedTracks.sorted { a, b in
                    let ia = orderMap[a.songHash] ?? Int.max
                    let ib = orderMap[b.songHash] ?? Int.max
                    return ia < ib
                }
            }()

            let mergedTracks = mergeTracks(
                existingTracks: existingTracks,
                importedTracks: orderedImportedTracks,
                clearExistingTracks: clearExistingTracks
            )

            await MainActor.run {
                self.hasLoadedProject = true
                self.showThankYouScreen = false
                self.showTempo = package.showTempo
                self.autoplayEnabled = package.autoplayEnabled
                self.autoplayDelaySeconds = package.autoplayDelaySeconds
                self.tracks = mergedTracks
                if let previousActiveSongHash,
                   let index = self.tracks.firstIndex(where: { $0.songHash == previousActiveSongHash }) {
                    self.currentIndex = index
                } else if !self.tracks.isEmpty {
                    self.currentIndex = 0
                } else {
                    self.currentIndex = nil
                }

                self.synchronizeActiveTrackSettings()
                self.persistTracksToLibrary(self.tracks)
                self.saveCurrentProjectPackage()
                self.objectWillChange.send()

                // Upgrades gain tags written by an older analysis; a project already on the
                // current version opens with nothing to do.
                self.relevelLibraryGain()
            }

            print("Imported project package from \(projectFolderURL.path)")
        } catch {
            print("Failed importing project package: \(error.localizedDescription)")
        }
    }

    private func loadProjectPackage(from projectFolderURL: URL) throws -> ProjectPackageExport {
        let projectJSONURL = projectFolderURL.appendingPathComponent("project.json")
        let data = try Data(contentsOf: projectJSONURL)
        return try JSONDecoder().decode(ProjectPackageExport.self, from: data)
    }

    /// Loads the optional song_order.json and returns the ordered song hashes.
    private func loadSongOrder(from projectFolderURL: URL, fallbackTracks: [ProjectPackageTrack]) -> [String] {
        let orderURL = projectFolderURL.appendingPathComponent("song_order.json")
        if let data = try? Data(contentsOf: orderURL),
           let order = try? JSONDecoder().decode(ProjectPackageOrderExport.self, from: data),
           !order.songHashes.isEmpty {
            return order.songHashes
        }
        // Fallback: use the order already present in project.json
        return fallbackTracks.map { $0.songHash }
    }

    private func buildTracks(
        from package: ProjectPackageExport,
        filesFolderURL: URL,
        artworkFolderURL: URL,
        clientID: String,
        includeSpotify: Bool
    ) async throws -> [Track] {
        var importedTracks: [Track] = []
        let spotifyPackageTracks = package.tracks.filter { $0.source == .spotify }
        let spotifyInputs = includeSpotify ? spotifyPackageTracks.compactMap { $0.spotifyImportInput } : []
        // Without a usable key the local songs still open; the Spotify ones are left out.
        let fetchedSpotifyTracks = spotifyInputs.isEmpty
            ? []
            : try await spotifyService.importTracks(from: spotifyInputs, clientID: clientID)
        var spotifyIterator = fetchedSpotifyTracks.makeIterator()

        // `if let` rather than `guard … else { continue }` so a song that can't be rebuilt
        // still moves the progress bar instead of stalling it.
        for packageTrack in package.tracks {
            switch packageTrack.source {
            case .local:
                if var localTrack = try buildLocalTrack(
                    from: packageTrack,
                    filesFolderURL: filesFolderURL,
                    artworkFolderURL: artworkFolderURL
                ) {
                    // Projects only store DJ-chosen art, so anything else comes back from the
                    // audio file's own tags here.
                    if localTrack.artwork == nil {
                        localTrack.artwork = await embeddedArtwork(for: localTrack.url)
                    }
                    importedTracks.append(localTrack)
                }
            case .spotify:
                if includeSpotify,
                   packageTrack.spotifyImportInput != nil,
                   var fetchedTrack = spotifyIterator.next() {
                    applyProjectPackage(packageTrack, to: &fetchedTrack)
                    importedTracks.append(fetchedTrack)
                }
            }

            await MainActor.run { self.advanceImportProgress() }
        }

        return importedTracks
    }

    private func buildLocalTrack(
        from packageTrack: ProjectPackageTrack,
        filesFolderURL: URL,
        artworkFolderURL: URL
    ) throws -> Track? {
        guard let fileURL = resolvedAudioURL(for: packageTrack, filesFolderURL: filesFolderURL) else {
            print("Missing local file for imported track: \(packageTrack.title)")
            return nil
        }

        var track = Track(
            url: fileURL,
            title: packageTrack.title,
            artist: packageTrack.artist,
            duration: packageTrack.duration,
            artwork: projectArtworkImage(from: packageTrack, artworkFolderURL: artworkFolderURL) ?? packageTrack.artworkData.flatMap(NSImage.init(data:)),
            songHash: packageTrack.songHash,
            source: packageTrack.source,
            spotifyURI: packageTrack.spotifyURI,
            spotifyExternalURL: packageTrack.spotifyExternalURL.flatMap(URL.init(string:))
        )

        applyPersistedSettings(packageTrack.persistedTrack, to: &track)
        // Art that shipped inside the project was chosen by the DJ, so keep treating it as
        // an override even for projects saved before the flag existed.
        if packageTrack.artworkFileName != nil || packageTrack.artworkData != nil {
            track.hasCustomArtwork = true
        }
        return track
    }

    private func applyProjectPackage(_ packageTrack: ProjectPackageTrack, to track: inout Track) {
        applyPersistedSettings(packageTrack.persistedTrack, to: &track)
    }

    private func mergeTracks(existingTracks: [Track], importedTracks: [Track], clearExistingTracks: Bool) -> [Track] {
        guard !clearExistingTracks else {
            return importedTracks
        }

        let existingHashes = Set(existingTracks.map(\.songHash))
        var mergedTracks = existingTracks
        mergedTracks.append(contentsOf: importedTracks.filter { !existingHashes.contains($0.songHash) })
        return mergedTracks
    }

    private func persistTracksToLibrary(_ tracks: [Track]) {
        let library = DancePlayerLibrary(tracks: tracks.map { track in
            PersistedTrack(
                songHash: track.songHash,
                source: track.source,
                isSkipped: track.isSkipped,
                spotifyURI: track.spotifyURI,
                spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                manualBPM: track.manualBPM,
                fadeInDuration: track.fadeInDuration,
                fadeOutDuration: track.fadeOutDuration,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
                loudnessAnalysisVersion: track.loudnessAnalysisVersion,
                hasCustomArtwork: track.hasCustomArtwork,
                artworkData: track.persistableArtworkData
            )
        })

        writeLibrary(library)
    }

    /// Default starting location for folder-picker panels
    private var defaultPanelDirectoryURL: URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    private func uniqueProjectPackageFolderURL(
        in destinationDirectoryURL: URL,
        projectName: String
    ) -> URL {
        let fileManager = FileManager.default
        let baseName = sanitizeProjectName(projectName)
        var candidateURL = destinationDirectoryURL.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2

        while fileManager.fileExists(atPath: candidateURL.path) {
            candidateURL = destinationDirectoryURL.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }

        return candidateURL
    }

    private func projectPackageFileName(for track: Track) -> String {
        let safeHash = track.songHash.replacingOccurrences(of: ":", with: "_")
        let extensionName = track.url.pathExtension.isEmpty ? "audio" : track.url.pathExtension
        return "\(safeHash).\(extensionName)"
    }
    

    // Add this helper inside the PlayerController class in SharedModelsAndEngine.swift
    func generateLiveLibraryJSONData() -> Data? {
        // Reconstruct the structural format matching your JSON library model
        let currentTracksToPersist = self.tracks.map { track in
            PersistedTrack(
                songHash: track.songHash,
                source: track.source,
                isSkipped: track.isSkipped,
                spotifyURI: track.spotifyURI,
                spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                manualBPM: track.manualBPM,
                fadeInDuration: track.fadeInDuration,
                fadeOutDuration: track.fadeOutDuration,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
                loudnessAnalysisVersion: track.loudnessAnalysisVersion,
                hasCustomArtwork: track.hasCustomArtwork,
                artworkData: track.persistableArtworkData
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

        Task { [weak self] in
            guard let self else { return }

            let existingHashes = await MainActor.run {
                Set(self.tracks.map(\.songHash))
            }
            let missingSpotifyTracks = importedContainer.tracks.filter { importedTrack in
                (importedTrack.source ?? .local) == .spotify && !existingHashes.contains(importedTrack.songHash)
            }

            var fetchedSpotifyTracks: [Track] = []
            var spotifyImportError: String? = nil

            if !missingSpotifyTracks.isEmpty {
                await MainActor.run {
                    self.isSpotifyImporting = true
                    self.spotifyStatusMessage = "Importing \(missingSpotifyTracks.count) Spotify track\(missingSpotifyTracks.count == 1 ? "" : "s") from JSON..."
                }

                let clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""

                let inputs = missingSpotifyTracks.compactMap { self.spotifyImportInput(for: $0) }

                do {
                    let fetchedTracks = try await self.spotifyService.importTracks(from: inputs, clientID: clientID)

                    var updatedFetchedTracks: [Track] = []
                    for var track in fetchedTracks {
                        if let importedTrack = missingSpotifyTracks.first(where: { $0.songHash == track.songHash }) {
                            self.applyPersistedSettings(importedTrack, to: &track)
                        }
                        self.applyTaggedStyles(to: &track)
                        updatedFetchedTracks.append(track)
                    }
                    fetchedSpotifyTracks = updatedFetchedTracks
                } catch {
                    spotifyImportError = error.localizedDescription
                }
            }

            await MainActor.run {
                var importedOrderMap: [String: Int] = [:]
                for (index, importedTrack) in importedContainer.tracks.enumerated() {
                    importedOrderMap[importedTrack.songHash] = index
                }

                var updateCount = 0
                let activeTrackRef = self.currentIndex.flatMap { self.tracks.indices.contains($0) ? self.tracks[$0] : nil }

                for i in 0..<self.tracks.count {
                    let currentHash = self.tracks[i].songHash
                    if let importedTrack = importedContainer.tracks.first(where: { $0.songHash == currentHash }) {
                        self.applyPersistedSettings(importedTrack, to: &self.tracks[i])
                        self.applyTaggedStyles(to: &self.tracks[i])
                        self.saveTrack(self.tracks[i])
                        updateCount += 1
                    }
                }

                for fetchedTrack in fetchedSpotifyTracks where !self.tracks.contains(where: { $0.songHash == fetchedTrack.songHash }) {
                    self.tracks.append(fetchedTrack)
                    self.saveTrack(fetchedTrack)
                    updateCount += 1
                }

                withAnimation(.easeInOut(duration: 0.25)) {
                    self.objectWillChange.send()
                    self.tracks.sort { trackA, trackB in
                        let indexA = importedOrderMap[trackA.songHash]
                        let indexB = importedOrderMap[trackB.songHash]
                        switch (indexA, indexB) {
                        case (let a?, let b?): return a < b
                        case (_?, nil): return true
                        case (nil, _?): return false
                        case (nil, nil): return false
                        }
                    }

                    if let previousActiveTrack = activeTrackRef {
                        self.currentIndex = self.tracks.firstIndex(where: { $0.id == previousActiveTrack.id })
                    } else if self.currentIndex == nil, !self.tracks.isEmpty {
                        self.prepareTrack(index: 0, autoPlay: false)
                    }

                    self.synchronizeActiveTrackSettings()
                }

                self.isSpotifyImporting = false
                if let spotifyImportError {
                    self.spotifyStatusMessage = spotifyImportError
                } else if !missingSpotifyTracks.isEmpty {
                    self.spotifyStatusMessage = "Imported \(fetchedSpotifyTracks.count) Spotify track\(fetchedSpotifyTracks.count == 1 ? "" : "s") from JSON."
                }

                print("Import completed! Synced \(updateCount) tracks and reordered playlist queue layout. Missing local files stay at the end until added.")
            }
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

struct PointingHandCursorModifier: ViewModifier {
    /// A greyed-out control isn't offering anything, so it shouldn't claim to be clickable.
    @Environment(\.isEnabled) private var isEnabled
    /// `push` and `pop` have to stay balanced. Popping on every exit assumes each exit had a
    /// matching entry, which stops being true as soon as the push is conditional.
    @State private var isHoldingCursor = false

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering, isEnabled, !isHoldingCursor {
                NSCursor.pointingHand.push()
                isHoldingCursor = true
            } else if !hovering, isHoldingCursor {
                NSCursor.pop()
                isHoldingCursor = false
            }
        }
    }
}

struct ResizeCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Uses `set()` rather than push()/pop() so a drag that ends outside the row can't leave the cursor stack unbalanced.
struct GrabCursorModifier: ViewModifier {
    let isDragging: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                refreshCursor()
            }
            .onChange(of: isDragging) { _, _ in refreshCursor() }
    }

    private func refreshCursor() {
        if isDragging {
            NSCursor.closedHand.set()
        } else if isHovering {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }

    func grabCursor(isDragging: Bool) -> some View {
        modifier(GrabCursorModifier(isDragging: isDragging))
    }

    func resizeLeftRightCursor() -> some View {
        modifier(ResizeCursorModifier())
    }
}

/// Notices when the audience window is closed directly, so the View menu's checkmark clears.
final class DisplayWindowObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
