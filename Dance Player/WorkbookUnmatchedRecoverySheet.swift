//
//  WorkbookUnmatchedRecoverySheet.swift
//  Dance Player
//

import SwiftUI
import AppKit

/// Shown after a batch YouTube fetch finishes with some rows unmatched, offering ways to resolve them.
struct WorkbookUnmatchedRecoverySheet: View {
    @ObservedObject var player: PlayerController
    @Binding var rows: [WorkbookImportRow]
    let unmatchedRowIDs: [WorkbookImportRow.ID]
    /// Awaited before this sheet dismisses itself, so a slow Spotify connection shows a spinner instead of just closing.
    var onTryAllSpotify: (String) async -> Void
    var onRenameAndRetry: () -> Void
    var onImportAllLocally: () -> Void
    var onDismiss: () -> Void

    init(
        player: PlayerController,
        rows: Binding<[WorkbookImportRow]>,
        unmatchedRowIDs: [WorkbookImportRow.ID],
        onTryAllSpotify: @escaping (String) async -> Void,
        onRenameAndRetry: @escaping () -> Void,
        onImportAllLocally: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.player = player
        self._rows = rows
        self.unmatchedRowIDs = unmatchedRowIDs
        self.onTryAllSpotify = onTryAllSpotify
        self.onRenameAndRetry = onRenameAndRetry
        self.onImportAllLocally = onImportAllLocally
        self.onDismiss = onDismiss
        self._spotifyClientIDDraft = State(initialValue: player.spotifyClientID)
    }

    @State private var spotifyClientIDDraft: String
    @State private var isConnectingSpotify = false

    private var unmatchedRows: [WorkbookImportRow] {
        rows.filter { unmatchedRowIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some Matches Couldn't Be Found")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    Text("\(unmatchedRows.count) song\(unmatchedRows.count == 1 ? "" : "s") didn't turn up a YouTube match. Do you want to try Spotify instead?")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(unmatchedRows) { row in
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle")
                                .foregroundColor(Color(hex: "#eab308"))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(row.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                Text(row.artist)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#71717a"))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 220)

            Divider().background(Color(hex: "#242429"))

            VStack(spacing: 8) {
                // Second line for the client ID -- shown inline rather than sending the DJ to
                // look for the bar at the top of the review screen, and editable even when one's
                // already set in case it's stale.
                VStack(alignment: .leading, spacing: 5) {
                    Text("SPOTIFY CLIENT ID")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                    TextField("Client ID", text: $spotifyClientIDDraft)
                        .textFieldStyle(.roundedBorder)
                }

                // Stays clickable even while a connection attempt is already in flight -- a
                // first-time Spotify sign-in can stall (the DJ closes the browser tab, the
                // approval page never loads), and there's no way to tell from here whether
                // that's what happened, so the way out is letting them just try again rather
                // than being locked behind a disabled button until something times out.
                Button(action: tryAllFromSpotify) {
                    HStack(spacing: 6) {
                        if isConnectingSpotify {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        }
                        Text(isConnectingSpotify ? "Connecting to Spotify… (click to retry)" : "Try Spotify Instead")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
                .disabled(spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Rename Songs & Try YouTube Again", action: onRenameAndRetry)
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                    .frame(maxWidth: .infinity)

                Button("Import All Locally", action: onImportAllLocally)
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                    .frame(maxWidth: .infinity)

                Button("Close", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
                    .pointingHandCursor()
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .frame(width: 420)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
    }

    /// A retry cancels whatever attempt was already running rather than piling a second one on
    /// top of it.
    @State private var connectTask: Task<Void, Never>?

    private func tryAllFromSpotify() {
        let clientID = spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return }
        connectTask?.cancel()
        isConnectingSpotify = true
        connectTask = Task {
            await onTryAllSpotify(clientID)
            guard !Task.isCancelled else { return }
            isConnectingSpotify = false
            onDismiss()
        }
    }
}

/// Steps through unmatched rows one at a time: rename and retry, or bail out via Spotify or a local file.
struct WorkbookRenameRetrySheet: View {
    @ObservedObject var player: PlayerController
    @Binding var rows: [WorkbookImportRow]
    let rowIDs: [WorkbookImportRow.ID]
    /// Called with whichever row ids (from the current one onward) should be switched to a
    /// local file pick, ending this sheet.
    var onImportRemainingLocally: ([WorkbookImportRow.ID]) -> Void
    var onFinished: () -> Void

    @State private var stepIndex = 0
    @State private var draftTitle = ""
    @State private var draftArtist = ""
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var lastResult: PlayerController.ITunesSearchResult?

    // The "Try All From Spotify" escape hatch for whichever row is currently showing.
    @State private var isPresentingSpotifyPicker = false
    @State private var spotifyPickerResults: [Track] = []
    @State private var isSearchingSpotifyPicker = false
    @State private var spotifyClientIDDraft = ""

    private var isLastStep: Bool { stepIndex >= rowIDs.count - 1 }

    private var currentRowIndex: Int? {
        guard rowIDs.indices.contains(stepIndex) else { return nil }
        let id = rowIDs[stepIndex]
        return rows.firstIndex { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))

            if let index = currentRowIndex {
                content(for: index)
            } else {
                VStack {
                    Text("All done")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().background(Color(hex: "#242429"))
            footer
        }
        .frame(width: 460, height: 580)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
        .onAppear { loadDraft() }
        .sheet(isPresented: $isPresentingSpotifyPicker) {
            spotifyPickerSheet
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Rename & Try Again")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("Song \(min(stepIndex + 1, rowIDs.count)) of \(rowIDs.count)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private func content(for index: Int) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TITLE")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("ARTIST")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                    TextField("Artist", text: $draftArtist)
                        .textFieldStyle(.roundedBorder)
                }

                Button(action: tryAgain) {
                    HStack(spacing: 6) {
                        if isSearching {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isSearching ? "Searching…" : "Try Again")
                    }
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
                .disabled(isSearching || draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasSearched {
                    if let lastResult {
                        HStack(spacing: 8) {
                            AsyncImage(url: lastResult.artworkURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Image(systemName: "music.note").foregroundColor(.gray)
                            }
                            .frame(width: 34, height: 34)
                            .background(Color(hex: "#18181b"))
                            .cornerRadius(4)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(lastResult.trackName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white)
                                Text(lastResult.artistName)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#71717a"))
                            }
                        }
                    } else {
                        Text("No match found for that title/artist — try renaming it again, or resolve it a different way below.")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#eab308"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Divider().background(Color(hex: "#242429"))

                Text("Or resolve this one a different way:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#71717a"))

                HStack(spacing: 8) {
                    Button("Try All From Spotify") { presentSpotifyPicker(for: index) }
                        .buttonStyle(.bordered)
                        .pointingHandCursor()

                    Button("Import All Locally") {
                        onImportRemainingLocally(Array(rowIDs[stepIndex...]))
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Button("Stop") { onFinished() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#71717a"))
                .pointingHandCursor()

            Spacer()

            Button(isLastStep ? "Done" : "Next") { advance() }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
        }
        .padding(16)
    }

    private func loadDraft() {
        guard let index = currentRowIndex else { return }
        draftTitle = rows[index].title
        draftArtist = rows[index].artist
        hasSearched = rows[index].youtubeSearchAttempted
        lastResult = rows[index].youtubeMatch
    }

    private func tryAgain() {
        guard let index = currentRowIndex else { return }
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = draftArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        isSearching = true
        Task {
            let cleanedTitle = PlayerController.cleanedYouTubeStyleTitle(title)
            let query = (artist.isEmpty || artist == "Unknown Artist") ? cleanedTitle : "\(artist) \(cleanedTitle)"
            let results = await player.fetchITunesResults(query: query)
            await MainActor.run {
                rows[index].title = title
                rows[index].artist = artist
                rows[index].youtubeCandidates = results
                rows[index].youtubeMatch = results.first
                rows[index].youtubeSearchAttempted = true
                rows[index].isYouTubeApproved = results.first != nil
                lastResult = results.first
                hasSearched = true
                isSearching = false
            }
        }
    }

    private func advance() {
        if isLastStep {
            onFinished()
        } else {
            stepIndex += 1
            loadDraft()
        }
    }

    // MARK: Spotify picker for the current track

    private func presentSpotifyPicker(for index: Int) {
        spotifyClientIDDraft = player.spotifyClientID
        spotifyPickerResults = []
        isPresentingSpotifyPicker = true
        if !spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            searchSpotifyPicker(for: index)
        }
    }

    private func searchSpotifyPicker(for index: Int) {
        let clientID = spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, rows.indices.contains(index) else { return }
        player.spotifyClientID = clientID
        isSearchingSpotifyPicker = true
        Task {
            let results = await player.searchWorkbookSpotifyTracks(
                title: rows[index].title,
                artist: rows[index].artist,
                clientID: clientID
            )
            await MainActor.run {
                spotifyPickerResults = results
                isSearchingSpotifyPicker = false
            }
        }
    }

    /// The song title/artist up top with a list of candidates to pick from below -- the same
    /// shape as the standalone Spotify import sheet, just scoped to this one unmatched row.
    @ViewBuilder
    private var spotifyPickerSheet: some View {
        if let index = currentRowIndex, rows.indices.contains(index) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rows[index].title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        Text(rows[index].artist)
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#71717a"))
                    }
                    Spacer()
                    Button(action: { isPresentingSpotifyPicker = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                .padding(16)

                Divider().background(Color(hex: "#242429"))

                // Second line for the client ID, needed the moment Spotify is picked as a source.
                if spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SPOTIFY CLIENT ID")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.gray)
                        HStack(spacing: 8) {
                            TextField("Client ID", text: $spotifyClientIDDraft)
                                .textFieldStyle(.roundedBorder)
                            Button("Search") { searchSpotifyPicker(for: index) }
                                .buttonStyle(WorkbookPrimaryButtonStyle())
                                .pointingHandCursor()
                                .disabled(spotifyClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(16)
                    Divider().background(Color(hex: "#242429"))
                }

                if isSearchingSpotifyPicker {
                    VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if spotifyPickerResults.isEmpty {
                    VStack(spacing: 6) {
                        Text("No matches yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.gray)
                        Text("Enter a client ID above and search, or adjust the title/artist and try again.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#52525b"))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(spotifyPickerResults) { track in
                                SpotifySearchResultRow(track: track) {
                                    rows[index].remoteSource = .spotify
                                    rows[index].spotifyMatch = track
                                    rows[index].spotifySearchAttempted = true
                                    rows[index].isSpotifyApproved = true
                                    isPresentingSpotifyPicker = false
                                    advance()
                                }
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .frame(width: 420, height: 480)
            .background(Color(hex: "#111114"))
            .preferredColorScheme(.dark)
        }
    }
}
