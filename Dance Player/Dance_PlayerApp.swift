//
//  Dance_PlayerApp.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/14/26.
//

import SwiftUI
import AppKit
import Combine

/// Holds a `.dbdj` handed to the app by Finder until the player is ready to load it —
/// the open request can arrive before (or after) `ContentView` exists.
final class ProjectFileOpenRequest: ObservableObject {
    static let shared = ProjectFileOpenRequest()

    /// Carries an id as well as the URL. `@Published` fires from `willSet`, so a subscriber that
    /// re-reads the property sees the old value; the URL must come from the publisher. The id
    /// lets the view skip a request it already handled.
    struct Request: Equatable {
        let id = UUID()
        let url: URL
    }

    @Published var pending: Request? = nil

    func post(_ url: URL) {
        pending = Request(url: url)
    }
}

final class DancePlayerAppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears, so termination can flush the player's pending save.
    weak var player: PlayerController?
    private var isWaitingForFinalSave = false

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            $0.pathExtension.lowercased() == PlayerController.projectFileExtension
        }) else { return }
        ProjectFileOpenRequest.shared.post(url)
    }

    /// Autosaves are debounced then written on a background queue, so quitting right after an
    /// edit used to kill the write. Hold termination until it lands.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let player, !isWaitingForFinalSave else { return .terminateNow }

        isWaitingForFinalSave = true
        player.flushPendingSaves {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct Dance_PlayerApp: App {
    @NSApplicationDelegateAdaptor(DancePlayerAppDelegate.self) private var appDelegate
    /// Owned here rather than in `ContentView` so the menu bar commands can reach it.
    @StateObject private var player = PlayerController()

    init() {
        if let iconURL = Bundle.main.url(forResource: "logo", withExtension: "jpg"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(player: player)
                .onAppear { appDelegate.player = player }
        }
        .commands {
            // Replaces SwiftUI's stock "New Item" so File reads as project actions.
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { player.isPresentingNewProject = true }
                    .keyboardShortcut("n", modifiers: .command)

                Button("Open Existing Project…") {
                    player.beginImportProjectFlow(named: "", autosaveRequested: true)
                }
                .keyboardShortcut("o", modifiers: .command)

                Divider()
            }

            CommandGroup(replacing: .undoRedo) {
                Button(player.undoActionLabel.map { "Undo \($0)" } ?? "Undo") {
                    player.undoLastChange()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(player.undoActionLabel == nil)

                Button(player.redoActionLabel.map { "Redo \($0)" } ?? "Redo") {
                    player.redoLastChange()
                }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(player.redoActionLabel == nil)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save As…") { player.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!player.hasLoadedProject)

                Button("Export .dbdj…") { player.exportProjectFile() }
                    .disabled(!player.hasLoadedProject)
            }

            CommandGroup(after: .toolbar) {
                Toggle("Open Audience View", isOn: Binding(
                    get: { player.isDisplayWindowOpen },
                    set: { shouldOpen in
                        if shouldOpen {
                            player.openDisplayWindow()
                        } else {
                            player.closeDisplayWindow()
                        }
                    }
                ))
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!player.hasLoadedProject)

                Button("Download All Spotify Tracks…") { player.isPresentingBulkDownloadConfirmation = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!player.hasLoadedProject || player.tracks.allSatisfy { $0.source != .spotify })

                Toggle("Cover Art Picker", isOn: Binding(
                    get: { player.isCoverArtWindowOpen },
                    set: { shouldOpen in
                        if shouldOpen {
                            player.openCoverArtWindow()
                        } else {
                            player.closeCoverArtWindow()
                        }
                    }
                ))
                .disabled(!player.hasLoadedProject)

                Divider()

                Button("Configure Set Clock…") { player.isPresentingSetClockConfig = true }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(!player.hasLoadedProject)

                Button("Detect BPM for All Songs") { player.detectBPMForLibrary() }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!player.hasLoadedProject || player.isImportingContent)
            }

            CommandMenu("Settings") {
                Toggle("Show Tempo", isOn: $player.showTempo)
                Toggle("Autoplay Next Song", isOn: $player.autoplayEnabled)

                Divider()

                Button("Advanced Settings…") {
                    // Set before presenting, so animations stop before the sheet builds.
                    player.isAdvancedSettingsOpen = true
                    player.isPresentingAdvancedSettings = true
                }
                Button("Set Spotify API Key…") { player.isPresentingSpotifyKeyEditor = true }
            }
        }
    }
}

/// Standalone editor for the Spotify API key, reachable from Settings ▸ Set Spotify API Key.
struct SpotifyKeyEditor: View {
    @ObservedObject var player: PlayerController
    var onDismiss: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Spotify API Key")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(16)

            Divider().background(Color(hex: "#242429"))

            VStack(alignment: .leading, spacing: 8) {
                Text("CLIENT ID")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)

                TextField("Paste your Spotify client ID", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))

                Text("Used to match workbook songs to Spotify and to play Spotify tracks. "
                     + "Create one at developer.spotify.com under any app you own.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            HStack {
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    player.spotifyClientID = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420)
        .background(Color(hex: "#0e0e10"))
        .onAppear { draft = player.spotifyClientID }
    }
}
