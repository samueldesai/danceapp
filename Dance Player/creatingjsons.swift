//
//  creatingjsons.swift
//  This file can be used to add data to the json files for the 
//  Dance Player
//
//  Created by Samuel Desai on 6/17/26.
//

import Foundation

struct SpotifyTaggedPlaylistManifest {
    let styleName: String
    let outputFileName: String
    let playlistURLs: [String]
}

private struct SpotifyEmbedNextData: Decodable {
    let props: SpotifyEmbedProps
}

private struct SpotifyEmbedProps: Decodable {
    let pageProps: SpotifyEmbedPageProps
}

private struct SpotifyEmbedPageProps: Decodable {
    let state: SpotifyEmbedState
}

private struct SpotifyEmbedState: Decodable {
    let data: SpotifyEmbedData
}

private struct SpotifyEmbedData: Decodable {
    let entity: SpotifyEmbedPlaylistEntity
}

private struct SpotifyEmbedPlaylistEntity: Decodable {
    let title: String?
    let name: String?
    let trackList: [SpotifyEmbedPlaylistTrack]?
}

private struct SpotifyEmbedPlaylistTrack: Decodable {
    let uri: String?
    let title: String?
    let subtitle: String?
    let isPlayable: Bool?
    let entityType: String?
}

private struct SpotifyTaggedExport: Codable {
    let styles: [SpotifyTaggedStyleExport]
}

private struct SpotifyTaggedStyleExport: Codable {
    let styleName: String
    let tracks: [SpotifyTaggedExportTrack]
}

private struct SpotifyTaggedExportTrack: Codable {
    let startTime: Double
    let spotifyURI: String
    let title: String
    let spotifyExternalURL: String
    let danceStyles: [String]
    let songHash: String
    let tempoPercentage: Double
    let customStyle: String
    let gainCorrectiondB: Double
    let artist: String
    let source: String
}

final class SpotifyTaggedJSONExporter {
    static let shared = SpotifyTaggedJSONExporter()

    private let manifests: [SpotifyTaggedPlaylistManifest] = [
        // Configure one manifest per style. If multiple manifests share the same
        // outputFileName, they are written into the same JSON file as separate
        // style sections.
        //
        // Example:
        // SpotifyTaggedPlaylistManifest(
        //     styleName: "Rotary Waltz",
        //     outputFileName: "data",
        //     playlistURLs: [
        //         "https://open.spotify.com/playlist/....",
        //         "https://open.spotify.com/playlist/...."
        //     ]
        // )
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Rotary Waltz",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/3jXeLJj4I4vsO3ITcJjQLl?si=5fc5fd085f604458",
                 "https://open.spotify.com/playlist/0zJoCwni8ABQKYBCh6O97Q?si=57d98bbb7f864df2"
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Cross-Step Waltz",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/0yhE1yIr8og4fAhs3WOxx1?si=48a00ad4817c4f25"
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Lindy Hop",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/5Bzafe1hEMEx9SzlpqytWu?si=19f1d0a6b67e4c3e",
                 "https://open.spotify.com/playlist/7Jr8lwVYBjLJbIrvWLtZKJ?si=b284ce5c00eb4a13"
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Fusion",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/2TzvChUNzxi48IVySgx9VN?si=5dd52be5ccd045e3",
                 "https://open.spotify.com/playlist/3YX12kg68OkYC5QKMpFrgO?si=917932c4ba2943a2",
                 "https://open.spotify.com/playlist/1EJVmbZP4BgxzFdcPMkAjZ?si=f42ab958378b4f8a",
                 "https://open.spotify.com/playlist/34Fmbpv3SK5VgX4S0G91EB?si=af390eba47434f75",
                 "https://open.spotify.com/playlist/3IVWY5ZC9J5c8YVo3DYvTd?si=47210b2fb72f46f8",
                 "https://open.spotify.com/playlist/5BHR47gxCI6J8RtaYci5t8?si=a4b7a40ba3d44d76",
                 "https://open.spotify.com/playlist/7lEEeWIx8UC7SjGLqwHMBy?si=fc2e80cca6a34d65",
                 "https://open.spotify.com/playlist/6Ykhx4ejxlnyXu1KlAAzyn?si=a97cdb20906f4545",
                 "https://open.spotify.com/playlist/6NkCXABQWQuQyHuVBa2qWX?si=f8517c0ded044d22",
                 "https://open.spotify.com/playlist/3akJsmHn9qv4W0R5moII7v?si=45b60d1154f94bfe",
                 "https://open.spotify.com/playlist/7xp2f4nS0ra5tMEV35j85O?si=6bfc7ed9d93a4ad8",
                 "https://open.spotify.com/playlist/2veoeR0VOKjHKHl6W1wstM?si=fc7b3b9105fb4386",
                 "https://open.spotify.com/playlist/5YiWIlZnFwjKoOJSLfWwqy?si=86429ef5db234a27",
                 "https://open.spotify.com/playlist/024UiVPXDBd1N7qF8uLuBe?si=6f65d211f2da4c43",
                 "https://open.spotify.com/playlist/0oflkKYdYDSBY2xjTf6k0l?si=0ab2f1bcf5b44207",
                 "https://open.spotify.com/playlist/3LhI52YAW7M6P8qnPzxvPN?si=b140f0bc0bf94e19",
                 "https://open.spotify.com/playlist/5qqTxdVi6F83Vz3DaCknRo?si=ca6db80c0b024ace"
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "West Coast Swing",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/3tLyLIetButHdRgLo8R2Z8?si=63ca793501144ac7",
                 "https://open.spotify.com/playlist/7HeO2le2z5ycFIf4HYo3yV?si=98e1a2728cfc4264",
                 "https://open.spotify.com/playlist/1McBGYZFVjaLkk9AQypwGr?si=799e667aabf34838",
                 "https://open.spotify.com/playlist/0uKeOb3GIXw3qlgYOIuP23?si=f08a7eb9399548cf",
                 "https://open.spotify.com/playlist/3278sHJ8KfLdoskScWGVXR?si=1fdc0b930dc64645",
                 "https://open.spotify.com/playlist/4XqdnCHcyU5XlLPP5xL3Zp?si=bab68f6b663b4091"
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Bachata",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/3TWVORtUAI2m8qzcpc8tjk?si=22883e7dea0f45bd",
             ]),
        
        SpotifyTaggedPlaylistManifest(
             styleName: "Salsa",
             outputFileName: "data",
             playlistURLs: [
                 "https://open.spotify.com/playlist/4CjUyBG13Fq246QZEv7T5Y?si=f51a7c84b28e4e3c",
             ]),
             
             
    ]

    func runOnLaunch() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            return
        }

        guard !manifests.isEmpty else {
            print("Spotify tagged JSON exporter is idle because no playlist manifests are configured.")
            return
        }

        Task(priority: .utility) { [manifests] in
            await self.generateAll(manifests: manifests)
        }
    }

    func generateAll() async {
        await generateAll(manifests: manifests)
    }

    private func generateAll(manifests: [SpotifyTaggedPlaylistManifest]) async {
        let groupedManifests = Dictionary(grouping: manifests, by: { $0.outputFileName })

        for outputFileName in groupedManifests.keys.sorted() {
            guard let styleManifests = groupedManifests[outputFileName] else { continue }

            do {
                try await generate(outputFileName: outputFileName, manifests: styleManifests)
            } catch {
                print("Failed exporting tagged JSON file '\(outputFileName).json': \(error)")
            }
        }
    }

    private func generate(outputFileName: String, manifests: [SpotifyTaggedPlaylistManifest]) async throws {
        guard !manifests.isEmpty else { return }

        let exportURL = taggedJSONDirectoryURL()
            .appendingPathComponent(outputFileName)
            .appendingPathExtension("json")

        var styleSections: [SpotifyTaggedStyleExport] = []
        var allPlaylistTitles: [String] = []

        for manifest in manifests {
            guard !manifest.playlistURLs.isEmpty else {
                print("Skipped style '\(manifest.styleName)' because it has no playlist URLs.")
                continue
            }

            let styleTracks = try await fetchTracks(for: manifest.playlistURLs)
            allPlaylistTitles.append(contentsOf: styleTracks.playlistTitles)
            styleSections.append(
                SpotifyTaggedStyleExport(
                    styleName: manifest.styleName,
                    tracks: styleTracks.tracks
                )
            )
        }

        guard !styleSections.isEmpty else {
            print("Skipped writing \(exportURL.lastPathComponent) because no playable tracks were found.")
            return
        }

        let export = SpotifyTaggedExport(styles: styleSections)
        let data = try encode(export)

        try FileManager.default.createDirectory(
            at: exportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if let existingData = try? Data(contentsOf: exportURL), existingData == data {
            print("No changes for \(exportURL.lastPathComponent); export left in place.")
            return
        }

        try data.write(to: exportURL, options: .atomic)
        print(
            "Exported \(styleSections.count) style section(s) to \(exportURL.lastPathComponent) from playlists: \(allPlaylistTitles.joined(separator: ", "))"
        )
    }

    private func fetchTracks(for playlistURLs: [String]) async throws -> (tracks: [SpotifyTaggedExportTrack], playlistTitles: [String]) {
        var uniqueHashes = Set<String>()
        var exportedTracks: [SpotifyTaggedExportTrack] = []
        var playlistTitles: [String] = []

        for playlistInput in playlistURLs {
            let playlistID = try spotifyID(from: playlistInput, expectedKind: "playlist")
            let page = try await fetchPlaylistEmbedPage(for: playlistID)

            let playlistTitle = page.props.pageProps.state.data.entity.title
                ?? page.props.pageProps.state.data.entity.name
                ?? playlistInput
            playlistTitles.append(playlistTitle)

            let tracks = page.props.pageProps.state.data.entity.trackList ?? []
            for track in tracks {
                guard track.entityType == "track" || track.entityType == nil else { continue }
                guard track.isPlayable ?? true else { continue }
                guard let uri = track.uri, uri.hasPrefix("spotify:track:") else { continue }

                let trackID = String(uri.dropFirst("spotify:track:".count))
                let songHash = "spotify:\(trackID)"
                guard uniqueHashes.insert(songHash).inserted else { continue }

                let title = normalizedText(track.title, fallback: "Unknown Title")
                let artist = normalizedText(track.subtitle, fallback: "Unknown Artist")

                exportedTracks.append(
                    SpotifyTaggedExportTrack(
                        startTime: 0,
                        spotifyURI: uri,
                        title: title,
                        spotifyExternalURL: "https://open.spotify.com/track/\(trackID)",
                        danceStyles: [],
                        songHash: songHash,
                        tempoPercentage: 0,
                        customStyle: "",
                        gainCorrectiondB: 0,
                        artist: artist,
                        source: "spotify"
                    )
                )
            }
        }

        return (exportedTracks, playlistTitles)
    }

    private func fetchPlaylistEmbedPage(for playlistID: String) async throws -> SpotifyEmbedNextData {
        let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(playlistID)")!
        var request = URLRequest(url: embedURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data, url: embedURL)

        guard let html = String(data: data, encoding: .utf8) else {
            throw SpotifyTaggedJSONExporterError.invalidPageContent
        }

        let jsonData = try extractNextDataJSON(from: html)
        return try JSONDecoder().decode(SpotifyEmbedNextData.self, from: jsonData)
    }

    private func extractNextDataJSON(from html: String) throws -> Data {
        let marker = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
        guard let startRange = html.range(of: marker) else {
            throw SpotifyTaggedJSONExporterError.missingNextData
        }

        guard let endRange = html[startRange.upperBound...].range(of: "</script>") else {
            throw SpotifyTaggedJSONExporterError.missingNextData
        }

        let jsonString = String(html[startRange.upperBound..<endRange.lowerBound])
        guard let data = jsonString.data(using: .utf8) else {
            throw SpotifyTaggedJSONExporterError.invalidPageContent
        }

        return data
    }

    private func encode(_ export: SpotifyTaggedExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(export)
    }

    private func validate(response: URLResponse, data: Data, url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyTaggedJSONExporterError.requestFailed("Spotify returned an unexpected response for \(url.absoluteString).")
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            let body = String(data: data.prefix(512), encoding: .utf8) ?? ""
            throw SpotifyTaggedJSONExporterError.requestFailed(
                "Spotify embed request failed with status \(httpResponse.statusCode) for \(url.lastPathComponent). \(body)"
            )
        }
    }

    private func spotifyID(from input: String, expectedKind: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpotifyTaggedJSONExporterError.invalidSpotifyIdentifier
        }

        if trimmed.hasPrefix("spotify:\(expectedKind):") {
            return String(trimmed.split(separator: ":").last ?? "")
        }

        if let url = URL(string: trimmed), url.host?.contains("spotify.com") == true {
            let components = url.pathComponents.filter { $0 != "/" }
            if let kindIndex = components.firstIndex(of: expectedKind),
               components.indices.contains(kindIndex + 1) {
                return components[kindIndex + 1]
            }
        }

        if trimmed.range(of: #"^[A-Za-z0-9]{16,}$"#, options: .regularExpression) != nil {
            return trimmed
        }

        throw SpotifyTaggedJSONExporterError.invalidSpotifyIdentifier
    }

    private func normalizedText(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func taggedJSONDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("DancePlayer", isDirectory: true)
            .appendingPathComponent("tagged_jsons", isDirectory: true)
    }
}

private enum SpotifyTaggedJSONExporterError: LocalizedError {
    case invalidSpotifyIdentifier
    case invalidPageContent
    case missingNextData
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidSpotifyIdentifier:
            return "That Spotify playlist link was not recognized."
        case .invalidPageContent:
            return "Spotify embed page content could not be parsed."
        case .missingNextData:
            return "Spotify embed page did not include the expected JSON payload."
        case .requestFailed(let message):
            return message
        }
    }
}
