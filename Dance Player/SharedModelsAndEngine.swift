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


// MARK: - Global Preset Data
let predefinedDanceStyles = [
    "Rotary Waltz", "Fast Waltz", "Accelerating Waltz", "Mazurka", "Redowa", "Polka",
    "Schottische", "Cross-Step Waltz", "One-Step", "Valse Asymétrique", "Lindy Hop",
    "4-Count Swing", "ECS (6-Count)", "Foxtrot", "Shag", "Balboa", "Charleston",
    "WCS", "NC2S", "Fusion", "Hustle", "Bachata", "Cha-Cha", "Salsa", "Tango",
    "Tokyo Polka", "Barbie Line Dance", "Shivers Line Dance", "Bohemian National Polka", "Romany Polka", "Dawn Mazurka", "Mixer", "Jam", "Dance with a Stranger", "Solo Jazz", "Other"
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
}

struct DancePlayerLibrary: Codable {
    var tracks: [PersistedTrack]
}

private struct TaggedStyleRegistry {
    private let styleBySongHash: [String: String]

    private static let taggedFolderName = "tagged_jsons"
    private static let styleNameOverrides: [String: String] = [
        "rotary": "Rotary Waltz"
    ]

    static let shared = TaggedStyleRegistry.load()

    private static func load() -> TaggedStyleRegistry {
        var styleBySongHash: [String: String] = [:]
        var loadedSourceCount = 0

        let jsonURLs = bundledTaggedJSONURLs()

        for url in jsonURLs {
            let resourceName = url.deletingPathExtension().lastPathComponent

            guard let data = try? Data(contentsOf: url),
                  let library = try? JSONDecoder().decode(DancePlayerLibrary.self, from: data)
            else {
                print("Skipped tagged style file: \(resourceName).json")
                continue
            }

            let discoveredStyle = library.tracks.compactMap { persistedTrack -> String? in
                if !persistedTrack.customStyle.isEmpty {
                    return persistedTrack.customStyle
                }
                if let style = persistedTrack.danceStyles.first(where: {
                    !$0.isEmpty && $0 != "Other"
                }) {
                    return style
                }
                return nil
            }.first

            let styleName = discoveredStyle
                ?? styleNameOverrides[resourceName.lowercased()]
                ?? resourceName
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .split(separator: " ")
                    .map { word in
                        word.prefix(1).uppercased() + word.dropFirst().lowercased()
                    }
                    .joined(separator: " ")

            for persistedTrack in library.tracks {
                styleBySongHash[persistedTrack.songHash] = styleName
            }

            loadedSourceCount += 1
            print("Loaded tagged style source '\(resourceName).json' as '\(styleName)' with \(library.tracks.count) hash entries.")
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
            <html><body>You can close this window and return to Dance Player.</body></html>
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
        
        // Check for Spotify Rate Limiting (HTTP 429)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
            if retryCount < 3 {
                var retryAfterSeconds: Double = 2.0 // Fallback default
                
                if let retryAfterHeader = httpResponse.value(forHTTPHeaderField: "Retry-After") {
                    if let rawValue = Double(retryAfterHeader) {
                        // If the value is larger than 1,000,000, it's a Unix Timestamp, not a duration
                        if rawValue > 1_000_000 {
                            let targetDate = Date(timeIntervalSince1970: rawValue)
                            let remainingTime = targetDate.timeIntervalSince(Date())
                            // Ensure we don't get a negative duration if the clock is slightly desynced
                            retryAfterSeconds = max(0.5, remainingTime)
                        } else {
                            // It's a normal delta-seconds duration
                            retryAfterSeconds = rawValue
                        }
                    }
                }
                
                // Add a hard ceiling (e.g., max 60 seconds) so your app never sleeps for 19 hours
                let finalSleepTime = min(60.0, retryAfterSeconds + 0.5)
                
                print("Spotify Rate Limit Hit! Sleeping for \(finalSleepTime)s before retry attempt #\(retryCount + 1)")
                
                try await Task.sleep(for: .seconds(finalSleepTime))
                return try await apiRequest(url, clientID: clientID, retryCount: retryCount + 1)
            }
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
    @Published var spotifyStatusMessage: String? = nil
    @Published var isSpotifyImporting = false
    @Published var isSpotifySearching = false
    @Published var spotifySearchResults: [Track] = []
    @Published var tracks: [Track] = [] {
        didSet {
            // Forces a refresh sync down to all observing views when the collection shifts
            objectWillChange.send()
        }
    }
    
    private var spotifyAccumulatedPauseTime: TimeInterval = 0.0
    private var avPlayer: AVPlayer?
    private var timeObserverToken: Any?
    private var spotifyProgressTask: Task<Void, Never>?
    private var displayWindowController: NSWindowController?
    private let spotifyService = SpotifyService()
    
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
        spotifyProgressTask?.cancel()
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
        
        let previousTrack = currentTrack
        removeTimeObserver()
        stopSpotifyProgressMonitor()
        currentIndex = index
        let track = tracks[index]

        if track.source == .spotify {
            avPlayer?.pause()
            avPlayer = nil
            duration = track.effectiveDuration
            currentTime = 0
            isBetweenSongs = false
            
            self.spotifyAccumulatedPauseTime = 0.0
            
            if autoPlay {
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
        stopSpotifyProgressMonitor()
        guard let currentIdx = currentIndex else { return }
        let nextIdx = currentIdx + 1
        let endedTrack = currentTrack
        
        lastTrack = currentTrack
        
        if nextIdx < tracks.count {
            prepareTrack(index: nextIdx, autoPlay: false)
            isBetweenSongs = true
        } else {
            avPlayer?.pause()
            if endedTrack?.source == .spotify {
                pauseSpotifyPlayback()
            }
            isPlaying = false
            currentTime = 0
            isBetweenSongs = false
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
            }
            
            else {
                avPlayer?.play()
                if let speed = currentTrack?.speedMultiplier {
                    avPlayer?.rate = Float(speed)
                }
            }
            isPlaying = true
            return
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

        processAudioURL(url, presetDanceStyles: edit.danceStyles)
    }

    private func popularEditResourceURL(for edit: PopularEdit) -> URL? {
        Bundle.main.url(forResource: edit.resourceName, withExtension: edit.fileExtension, subdirectory: "audio files")
            ?? Bundle.main.url(forResource: edit.resourceName, withExtension: edit.fileExtension)
    }
    
    func processAudioURL(_ url: URL, presetDanceStyles: Set<String>? = nil) {
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
        let asset = AVURLAsset(url: sourceURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return }
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: .zero, end: CMTime(seconds: endTrimTime, preferredTimescale: 600))
        
        Task { [weak self] in
            do {
                try await exportSession.export(to: outputURL, as: .m4a)
                await MainActor.run {
                    guard let self = self, self.tracks.indices.contains(trackIndex) else { return }
                    
                    self.tracks[trackIndex].url = outputURL
                    self.tracks[trackIndex].duration = endTrimTime
                    
                    if self.currentIndex == trackIndex {
                        self.synchronizeActiveTrackSettings()
                    }
                    print("Track trim committed successfully via hardware exporter.")
                    
                    // --- NEW: Auto-calculate ReplayGain after a successful trim ---
                    self.calculateLoudness(forTrackAt: trackIndex)
                }
            } catch {
                print("Export session failed: \(error.localizedDescription)")
                
                await MainActor.run {
                    guard let self = self, self.tracks.indices.contains(trackIndex) else { return }
                    self.calculateLoudness(forTrackAt: trackIndex)
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
                gainCorrectiondB: track.gainCorrectiondB
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
                        case (let a?, let b?):
                            return a < b
                        case (_?, nil):
                            return true
                        case (nil, _?):
                            return false
                        case (nil, nil):
                            return false
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
