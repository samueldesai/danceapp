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
import Network
import Security
import MediaPlayer


// MARK: - Global Preset Data
let predefinedDanceStyles = [
    "Cross-Step Waltz", "Rotary Waltz", "Lindy Hop", "West Coast Swing", "Fast Waltz", "Accelerating Waltz", "Mazurka", "Redowa", "Polka", "Schottische", "One-Step", "Valse Asymétrique", "4-Count Swing", "Foxtrot", "Shag", "Balboa", "Charleston", "Night Club Two Step", "Fusion", "Hustle", "Bachata", "Cha-Cha", "Salsa", "Tango", "Merengue", "Tokyo Polka", "Barbie Line Dance", "Shivers Line Dance", "Solo Jazz", "Bohemian National Polka", "Romany Polka", "Dawn Mazurka", "Mixer", "Jam", "Dance with a Stranger", "Last West Coast Swing", "Last Lindy Hop", "Last Cross-Step Waltz", "Last Rotary Waltz", "Other",
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
    var spotifyURI: String? = nil
    var spotifyExternalURL: URL? = nil

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
        let isJam = danceStyles.contains("Jam")
        let isWithStranger = danceStyles.contains("Dance with a Stranger")

        var items: [String] = []
        for style in predefinedDanceStyles {
            guard style != "Jam", style != "Dance with a Stranger" else { continue }
            if danceStyles.contains(style) {
                if style == "Other" && !customStyle.isEmpty {
                    items.append(customStyle)
                } else {
                    items.append(style)
                }
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
}

struct PersistedTrack: Codable {
    var songHash: String
    var source: TrackSource?
    var spotifyURI: String?
    var spotifyExternalURL: String?

    var title: String
    var artist: String

    var danceStyles: [String]
    var customStyle: String

    var startTime: Double
    var endTime: Double?
    var tempoPercentage: Double

    var measuredLoudness: Double?
    var gainCorrectiondB: Double
    var artworkData: Data? = nil
}

struct DancePlayerLibrary: Codable {
    var tracks: [PersistedTrack]
}

struct ProjectPackageExport: Codable {
    var version: Int = 1
    var projectName: String
    var tracks: [ProjectPackageTrack]

    private enum CodingKeys: String, CodingKey {
        case version
        case projectName
        case tracks
    }

    init(projectName: String, tracks: [ProjectPackageTrack], version: Int = 1) {
        self.version = version
        self.projectName = projectName
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? "Dance Player Project"
        tracks = try container.decodeIfPresent([ProjectPackageTrack].self, forKey: .tracks) ?? []
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

private extension NSImage {
    var projectPackageData: Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension Track {

    var persistableArtworkData: Data? {
        guard source == .local else { return nil }
        return artwork?.projectPackageData
    }
}

struct ProjectPackageTrack: Codable {
    var songHash: String
    var source: TrackSource
    var spotifyURI: String?
    var spotifyExternalURL: String?
    var title: String
    var artist: String
    var danceStyles: [String]
    var customStyle: String
    var startTime: Double
    var endTime: Double?
    var tempoPercentage: Double
    var measuredLoudness: Double?
    var gainCorrectiondB: Double
    var duration: Double
    var localFileName: String?
    var artworkFileName: String?
    var artworkData: Data?

    init(from track: Track, localFileName: String? = nil, artworkFileName: String? = nil) {
        self.songHash = track.songHash
        self.source = track.source
        self.spotifyURI = track.spotifyURI
        self.spotifyExternalURL = track.spotifyExternalURL?.absoluteString
        self.title = track.title
        self.artist = track.artist
        self.danceStyles = Array(track.danceStyles)
        self.customStyle = track.customStyle
        self.startTime = track.startTime
        self.endTime = track.endTime
        self.tempoPercentage = track.tempoPercentage
        self.measuredLoudness = track.measuredLoudness
        self.gainCorrectiondB = track.gainCorrectiondB
        self.duration = track.duration
        self.localFileName = localFileName
        self.artworkFileName = track.source == .local ? artworkFileName : nil
        self.artworkData = (track.source == .local && artworkFileName == nil) ? track.persistableArtworkData : nil
    }

    var persistedTrack: PersistedTrack {
        PersistedTrack(
            songHash: songHash,
            source: source,
            spotifyURI: spotifyURI,
            spotifyExternalURL: spotifyExternalURL,
            title: title,
            artist: artist,
            danceStyles: danceStyles,
            customStyle: customStyle,
            startTime: startTime,
            endTime: endTime,
            tempoPercentage: tempoPercentage,
            measuredLoudness: measuredLoudness,
            gainCorrectiondB: gainCorrectiondB,
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

enum SpotifyImportKind {
    case track
    case playlist
}

struct PopularEdit: Identifiable, CaseIterable {
    let id: String
    let displayName: String
    let resourceName: String
    let fileExtension: String
    let danceStyles: Set<String>

    static let allCases: [PopularEdit] = [
        PopularEdit(
            id: "barbie-line-dance",
            displayName: "Barbie Line Dance",
            resourceName: "Barbie Line Dance",
            fileExtension: "mp3",
            danceStyles: ["Barbie Line Dance"]
        ),
        PopularEdit(
            id: "bohemian-national-polka",
            displayName: "Bohemian National Polka",
            resourceName: "Bohemian National Polka",
            fileExtension: "mp3",
            danceStyles: ["Bohemian National Polka"]
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
            danceStyles: ["Tokyo Polka"]
        ),//TODO add T'Smidje Mixer
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
        
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            let finalSleepTime = 30.0
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

// MARK: - Audio Engine & Controller
class PlayerController: ObservableObject {
    @Published var projectName: String = "Dance Player Project"
    @Published var projectAutosaveParentURL: URL? = nil
    @Published var projectFolderURL: URL? = nil
    @Published var autosaveEnabled = false
    @Published var hasLoadedProject = false
    @Published var showThankYouScreen = false

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
    @Published var targetLoudnessLUFS: Double = -16.0
    @Published var isBatchProcessingLoudness = false
    @Published var loudnessBatchProgress: Double = 0.0
    
    @Published var lastTrack: Track? = nil
    @Published var isBetweenSongs = false
    @Published var selectedTrackForEditing: Track? = nil
    @Published var spotifyStatusMessage: String? = nil
    @Published var isSpotifyImporting = false
    @Published var isSpotifySearching = false
    @Published var spotifySearchResults: [Track] = []
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
    private var isPresentingCloseSavePrompt = false
    private var isHandlingSongEnd = false
    private var displayWindowController: NSWindowController?
    private let spotifyService = SpotifyService()
    private var spacebarKeyMonitor: Any?
    
    var isDraggingSlider = false

    var currentTrack: Track? {
        guard let idx = currentIndex, tracks.indices.contains(idx) else { return nil }
        return tracks[idx]
    }

    init() {
        setupRemoteCommandCenter()
        setupSpacebarKeyMonitor()
    }

    // MARK: - Media Key / Keyboard Shortcuts (F7 / F8 / F9 + Spacebar)

    /// Routes hardware media keys (F7/F8/F9, Touch Bar, Control Center "Now Playing") to playback controls.
    ///
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

    private func setupSpacebarKeyMonitor() {
        spacebarKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // keyCode 49 == spacebar
            guard event.keyCode == 49 else { return event }

            if self.isCurrentlyEditingText() {
                return event // let the text field handle it normally
            }

            self.togglePlayPause()
            return nil // swallow so it doesn't also trigger button focus / scroll, etc.
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

        guard let parent = projectAutosaveParentURL else { return nil }
        return parent.appendingPathComponent(safeProjectName, isDirectory: true)
    }

    private var projectFilesFolderURL: URL? {
        projectRootFolderURL?.appendingPathComponent("files", isDirectory: true)
    }

    private var projectArtworkFolderURL: URL? {
        projectRootFolderURL?.appendingPathComponent("artwork", isDirectory: true)
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

        do {
            _ = try exportProjectPackage(
                toProjectFolder: destinationDirectoryURL,
                projectName: safeProjectName,
                overwriteExisting: true
            )
        } catch {
            print("Failed autosaving project package: \(error.localizedDescription)")
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
            // Ensure both subdirectories exist before any file operation —
            // this matters when materialize is called on the first track add
            // before the autosave has had a chance to run createDirectory.
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

            if sourceURL.standardizedFileURL != destinationAudioURL.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destinationAudioURL.path) {
                    try FileManager.default.removeItem(at: destinationAudioURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationAudioURL)
            }

            track.url = destinationAudioURL

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
        guard let idx = currentIndex else { return Array(tracks.prefix(3)) }
        let start = idx + 1
        guard start < tracks.count else { return [] }
        return Array(tracks[start..<min(start + 3, tracks.count)])
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
        isHandlingSongEnd = false
        
        let previousTrack = previousTrackOverride ?? currentTrack
        removeTimeObserver()
        stopSpotifyProgressMonitor()
        showThankYouScreen = false
        currentIndex = index
        let track = tracks[index]

        if track.source == .spotify {
            avPlayer?.pause()
            avPlayer = nil
            duration = track.effectiveDuration
            currentTime = 0

            self.spotifyAccumulatedPauseTime = 0.0
            
            // Mirror the local-file branch below: only clear isBetweenSongs
            // (and actually start playback) when autoPlay is true. When
            // prepareTrack is called from handleSongEnded with autoPlay:false,
            // isBetweenSongs must stay true until the user presses Play —
            // otherwise the UI jumps straight to the "Now Playing" screen
            // while Spotify hasn't started playback yet (its API has a
            // noticeable delay), causing a flash to the wrong screen.
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

        guard !isHandlingSongEnd else { return }
        isHandlingSongEnd = true

        stopSpotifyProgressMonitor()
        guard let currentIdx = currentIndex else {
            isHandlingSongEnd = false
            return
        }
        let nextIdx = currentIdx + 1
        let endedTrack = currentTrack

        lastTrack = currentTrack

        if nextIdx < tracks.count {

            currentIndex = nextIdx
            duration = tracks[nextIdx].effectiveDuration
            currentTime = 0
            isPlaying = false
            isBetweenSongs = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.prepareTrack(index: nextIdx, autoPlay: false, previousTrackOverride: endedTrack)
                self.isHandlingSongEnd = false
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
    
    func togglePlayPause() {
        if isBetweenSongs {
            isBetweenSongs = false
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
                return
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
                return
            }
        }

        if let track = currentTrack, track.source == .spotify {
            if isPlaying {
                stopSpotifyProgressMonitor()
                pauseSpotifyPlayback()
                isPlaying = false
            } else {
                playSpotifyTrack(track)
                isPlaying = true
            }
            return
        }
        
        guard avPlayer != nil else {
            if let idx = currentIndex, tracks.indices.contains(idx), tracks[idx].source == .spotify {
                play(index: idx)
            } else if !tracks.isEmpty {
                play(index: 0)
            }
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
            play(index: idx + 1)
        }
    }
    
    func previous() {
        if let idx = currentIndex, idx - 1 >= 0 {
            play(index: idx - 1)
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
    }
    
    func removeTrack(at index: Int) {
        guard tracks.indices.contains(index) else { return }
        
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
        
        tracks.remove(at: index)
    }

    private func applyPersistedSettings(_ persistedTrack: PersistedTrack, to track: inout Track) {
        track.title = persistedTrack.title
        track.artist = persistedTrack.artist
        track.danceStyles = Set(persistedTrack.danceStyles)
        track.customStyle = persistedTrack.customStyle
        track.startTime = persistedTrack.startTime
        track.endTime = persistedTrack.endTime
        track.tempoPercentage = persistedTrack.tempoPercentage
        track.measuredLoudness = persistedTrack.measuredLoudness
        track.gainCorrectiondB = persistedTrack.gainCorrectiondB

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

        Task { [weak self] in
            guard let self else { return }

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

    func importPopularEdit(_ edit: PopularEdit) {
        guard let url = popularEditResourceURL(for: edit) else {
            print("Popular edit resource not found: \(edit.resourceName).\(edit.fileExtension)")
            return
        }

        processAudioURL(url, presetDanceStyles: edit.danceStyles, runReplayGainOnAdd: true)
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
                    startTime: startTime,
                    endTime: endTime,
                    tempoPercentage: tempoPercentage
                )

                self.applyTaggedStyles(to: &newTrack)
                self.materializeLocalTrackAssetsIfNeeded(
                    &newTrack,
                    sourceURL: url,
                    artwork: artwork
                )

                // FIX 1: Append EXACTLY ONCE
                self.tracks.append(newTrack)
                self.showThankYouScreen = false
                let trackIndex = self.tracks.count - 1

                if self.currentIndex == nil {
                    self.prepareTrack(index: 0, autoPlay: false)
                }

                if runReplayGainOnAdd {
                    self.calculateLoudness(forTrackAt: trackIndex)
                }

                // FIX 2: Trigger the background trailing silence trimmer.
                // Security scope is released inside trimTrailingSilence after
                // the async work completes so the file stays accessible during
                // the background scan and export.
                print("Starting trailing silence trim analysis for: \(title)")
                self.trimTrailingSilence(forTrackAt: trackIndex, releaseSecurityScope: accessSecure ? url : nil)
            }
        }
    }

    // MARK: - Core Audio Trimming Engine
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
                
                // Read chunks backward to find where the audio actually drops below -60dB
                let bufferSize = min(frameCount, 44100 * 2) // 2-second chunks
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                    scopedURL?.stopAccessingSecurityScopedResource()
                    return
                }
                
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
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
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
                    measuredLoudness: track.measuredLoudness,
                    gainCorrectiondB: track.gainCorrectiondB,
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
            guard let self else { return }
            await self.importProjectPackage(
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
        persistTracksToLibrary([])

        // Eagerly create the project folder structure so that
        // materializeLocalTrackAssetsIfNeeded works the moment the first
        // track is added — before the first autosave fires.
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

    func beginImportProjectFlow(named name: String, autosaveRequested: Bool) {
        let sanitizedName = sanitizeProjectName(name)
        let projectPanel = NSOpenPanel()
        projectPanel.allowsMultipleSelection = false
        projectPanel.canChooseDirectories = true
        projectPanel.canChooseFiles = false
        projectPanel.directoryURL = defaultPanelDirectoryURL
        projectPanel.message = "Choose an exported project folder."
        projectPanel.prompt = "Import"

        projectPanel.begin { [weak self] response in
            guard let self, response == .OK, let projectFolderURL = projectPanel.url else { return }

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

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = defaultPanelDirectoryURL
        panel.message = "Choose where the project should be saved."
        panel.prompt = "Save"

        panel.begin { [weak self] response in
            guard let self, response == .OK, let parentURL = panel.url else { return }
            DispatchQueue.main.async {
                self.projectName = newName
                
                let projectFolder = parentURL.appendingPathComponent(
                    self.sanitizeProjectName(newName), isDirectory: true
                )
                self.projectAutosaveParentURL = parentURL
                self.projectFolderURL = projectFolder
                self.autosaveEnabled = true
                self.hasLoadedProject = true
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
            var artworkFileName: String? = nil

            if track.source == .local, track.url.isFileURL {
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


            if track.source == .local, let artworkData = track.persistableArtworkData {
                artworkFileName = "\(track.songHash).png"
                let artworkURL = artworkFolderURL.appendingPathComponent(artworkFileName!)
                if fileManager.fileExists(atPath: artworkURL.path) {
                    try fileManager.removeItem(at: artworkURL)
                }
                try artworkData.write(to: artworkURL, options: .atomic)
            }

            exportedTracks.append(
                ProjectPackageTrack(
                    from: track,
                    localFileName: localFileName,
                    artworkFileName: artworkFileName
                )
            )
        }

        let package = ProjectPackageExport(
            projectName: sanitizedProjectName,
            tracks: exportedTracks
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
        do {
            let package = try loadProjectPackage(from: projectFolderURL)
            let clientID = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
            let filesFolderURL = projectFolderURL.appendingPathComponent("files", isDirectory: true)
            let artworkFolderURL = projectFolderURL.appendingPathComponent("artwork", isDirectory: true)
            let existingTracks = await MainActor.run { self.tracks }
            let previousActiveSongHash = await MainActor.run { self.currentTrack?.songHash }

            if package.tracks.contains(where: { $0.source == .spotify }) {
                do {
                    try await spotifyService.connect(clientID: clientID)
                    await MainActor.run {
                        self.spotifyStatusMessage = "Spotify connection confirmed."
                    }
                } catch {
                    print("Spotify connection check failed before project import: \(error.localizedDescription)")
                    return
                }
            }

            let importedTracks = try await buildTracks(
                from: package,
                filesFolderURL: filesFolderURL,
                artworkFolderURL: artworkFolderURL,
                clientID: clientID
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
        clientID: String
    ) async throws -> [Track] {
        var importedTracks: [Track] = []
        let spotifyPackageTracks = package.tracks.filter { $0.source == .spotify }
        let spotifyInputs = spotifyPackageTracks.compactMap { $0.spotifyImportInput }
        let fetchedSpotifyTracks = try await spotifyService.importTracks(from: spotifyInputs, clientID: clientID)
        var spotifyIterator = fetchedSpotifyTracks.makeIterator()

        for packageTrack in package.tracks {
            switch packageTrack.source {
            case .local:
                guard let localTrack = try buildLocalTrack(
                    from: packageTrack,
                    filesFolderURL: filesFolderURL,
                    artworkFolderURL: artworkFolderURL
                ) else { continue }
                importedTracks.append(localTrack)
            case .spotify:
                guard packageTrack.spotifyImportInput != nil else { continue }
                guard var fetchedTrack = spotifyIterator.next() else { continue }
                applyProjectPackage(packageTrack, to: &fetchedTrack)
                importedTracks.append(fetchedTrack)
            }
        }

        return importedTracks
    }

    private func buildLocalTrack(
        from packageTrack: ProjectPackageTrack,
        filesFolderURL: URL,
        artworkFolderURL: URL
    ) throws -> Track? {
        guard let fileName = packageTrack.localFileName else { return nil }
        let fileURL = filesFolderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("Missing local file for imported track: \(fileName)")
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
                spotifyURI: track.spotifyURI,
                spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
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
                spotifyURI: track.spotifyURI,
                spotifyExternalURL: track.spotifyExternalURL?.absoluteString,
                title: track.title,
                artist: track.artist,
                danceStyles: Array(track.danceStyles),
                customStyle: track.customStyle,
                startTime: track.startTime,
                endTime: track.endTime,
                tempoPercentage: track.tempoPercentage,
                measuredLoudness: track.measuredLoudness,
                gainCorrectiondB: track.gainCorrectiondB,
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
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursorModifier())
    }
}
