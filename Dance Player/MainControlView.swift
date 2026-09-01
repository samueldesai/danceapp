//
//  MainControlView.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/15/26.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine
import AppKit

// MARK: - WINDOW 1: Main Control View
struct ContentView: View {
    @ObservedObject var player: PlayerController
    @ObservedObject private var openRequest = ProjectFileOpenRequest.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Last Finder open request acted on, so it isn't opened twice.
    @State private var handledProjectRequestID: UUID? = nil

    var body: some View {
        ZStack {
            if let workbookRows = player.pendingWorkbookImport {
                WorkbookImportReviewView(
                    player: player,
                    rows: workbookRows,
                    onFinished: { player.clearWorkbookImportProgress() }
                )
            } else if player.hasLoadedProject {
                QueueSplitView(player: player)
                    .disabled(player.isImportingContent)
            } else {
                ProjectWelcomeView(player: player)
            }

            if player.isImportingContent {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()

                VStack(spacing: 12) {
                    if player.importProgressFraction != nil {
                        ProgressView(value: Double(player.importCompletedCount), total: Double(player.importTotalCount))
                            .controlSize(.large)
                            .frame(width: 280)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                    }

                    VStack(spacing: 4) {
                        Text(player.importStatusMessage ?? "Importing media...")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)

                        if let progressText = player.importProgressSummary {
                            Text(progressText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Color(hex: "#a3a3ac"))
                        }
                    }
                }
                .frame(maxWidth: 340)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .background(Color(hex: "#111114").opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(hex: "#2f2f38"), lineWidth: 1)
                )
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
            }

            // Same celebration as the audience screen; last in the ZStack so it's in front of everything.
            if showsJamConfetti {
                ConfettiView()
                    .edgesIgnoringSafeArea(.all)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: showsJamConfetti)
        .background(Color(hex: "#0e0e10"))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.15), value: player.isImportingContent)
        .navigationTitle(player.projectName)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                player.saveProjectOnCloseIfNeeded()
            }
        }
        // A .dbdj can arrive before this view exists, so also check on appear (deferred a tick since publishing here is undefined behavior).
        .onAppear {
            DispatchQueue.main.async {
                consumePendingProjectFile(openRequest.pending)
                player.relevelLibraryGainOnLaunch()
            }
        }
        // Closing the window leaves the app running, so save and unload here rather than waiting for a quit that may never come.
        .onDisappear {
            DispatchQueue.main.async {
                player.closeProjectAfterLastWindowClosed()
            }
        }
        .onReceive(openRequest.$pending) { request in
            DispatchQueue.main.async { consumePendingProjectFile(request) }
        }
        .sheet(isPresented: $player.isPresentingNewProject) {
            NewProjectDialog(player: player) { player.isPresentingNewProject = false }
        }
        .sheet(isPresented: $player.isPresentingAdvancedSettings) {
            AdvancedSettingsView(player: player)
                .onDisappear { player.isAdvancedSettingsOpen = false }
        }
        .sheet(isPresented: $player.isPresentingSpotifyKeyEditor) {
            SpotifyKeyEditor(player: player) { player.isPresentingSpotifyKeyEditor = false }
        }
        .confirmationDialog(
            "Download all Spotify tracks locally?",
            isPresented: $player.isPresentingBulkDownloadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Download All") { player.downloadAllSpotifyTracks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let count = player.tracks.filter { $0.source == .spotify }.count
            Text("This looks up a YouTube match for each of the \(count) Spotify track\(count == 1 ? "" : "s") in this project and switches them over to the downloaded local file. This can take a while for a large queue.")
        }
        .overlay {
            if player.isBulkDownloadingSpotifyTracks {
                BulkDownloadProgressOverlay(player: player)
            }
        }
        // Keyed on the song so the sheet rebuilds fresh per track; the draft timings and decoded waveform don't carry over.
        .sheet(isPresented: Binding(
            get: { player.timingEditorTrackID != nil },
            set: { if !$0 { player.closeTimingEditor() } }
        )) {
            if let trackID = player.timingEditorTrackID {
                TimingEditorView(player: player, trackID: trackID)
                    .id(trackID)
            }
        }
        .tutorialOverlayHost(for: [.mainControl, .workbookImporter])
    }

    /// Same rule as the audience screen's `showsConfetti` -- through the pivot call, the jam announcement, and the jam itself.
    private var showsJamConfetti: Bool {
        if player.isShowingPivots { return true }
        guard player.currentTrack?.isJam == true else { return false }
        return player.isBetweenSongs || player.isPlaying
    }

    /// Takes the URL from the request, not the published property, which still holds its old value while subscribers run.
    private func consumePendingProjectFile(_ request: ProjectFileOpenRequest.Request?) {
        guard let request, request.id != handledProjectRequestID else { return }
        handledProjectRequestID = request.id
        player.openProjectFile(at: request.url)
    }
}

/// Covers the whole window during "Download All Spotify Tracks" so the app doesn't look hung during a slow, one-at-a-time YouTube search.
struct BulkDownloadProgressOverlay: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView(
                    value: Double(player.bulkDownloadCompletedCount),
                    total: Double(max(player.bulkDownloadTotalCount, 1))
                )
                .frame(width: 260)

                Text("Downloading \(player.bulkDownloadCompletedCount) of \(player.bulkDownloadTotalCount)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                if let statusMessage = player.spotifyStatusMessage {
                    Text(statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                        .lineLimit(1)
                        .frame(maxWidth: 320)
                }
            }
            .padding(28)
            .background(Color(hex: "#18181b"))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(hex: "#27272a"), lineWidth: 1)
            )
        }
    }
}

struct ProjectWelcomeView: View {
    @ObservedObject var player: PlayerController
    @State private var recentProjects: [ProjectLocations.RecentProject] = []

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hex: "#111114"),
                    Color(hex: "#08080a"),
                    Color(hex: "#15151a")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 18) {
                    AppLogoView()
                        .frame(width: 128, height: 128)

                    VStack(spacing: 8) {
                        Text("Dance Player")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .foregroundColor(.white)

                        Text("Create or open a project package")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(Color(hex: "#a1a1aa"))
                    }
                }

                HStack(spacing: 14) {
                    Button("Create Project") {
                        player.isPresentingNewProject = true
                    }
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()

                    Button("Open Existing Project") {
                        player.beginImportProjectFlow(named: "", autosaveRequested: true)
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
                .controlSize(.large)

                if !recentProjects.isEmpty {
                    recentProjectsList
                }

                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 760)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("Created by Samuel Desai. Special thanks to Akshay Srivatsan, Ness Arikan, Wally Niu, Eddy Hudson, and Joseph Lucero for input.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#71717a"))
                        .padding(.trailing, 18)
                        .padding(.bottom, 12)
                }
            }
        }
        .onAppear { recentProjects = ProjectLocations.recentProjects() }
    }

    private var recentProjectsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "#71717a"))
                    .tracking(0.6)
                Spacer()
                Button("Clear") {
                    ProjectLocations.clearRecentProjects()
                    recentProjects = []
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#71717a"))
                .pointingHandCursor()
            }

            ForEach(recentProjects) { recent in
                Button {
                    guard let url = ProjectLocations.openRecent(recent) else { return }
                    player.openProjectFile(at: url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#3478f6"))
                        Text(recent.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#111114").opacity(0.9))
                    .cornerRadius(6)
                    .help(recent.url.path)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .frame(maxWidth: 420)
    }
}

/// A single dialog rather than a form plus three buttons that each opened a different panel.
struct NewProjectDialog: View {
    @ObservedObject var player: PlayerController
    var onDismiss: () -> Void

    @State private var projectName: String = ""
    /// Chosen by the DJ via Browse; since autosave is always on, this is simply where the project's .dbdj lives.
    @State private var projectFolderURL: URL? = nil
    @State private var importFromWorkbook: Bool = false
    @State private var workbookURL: URL? = nil
    @State private var runTutorialAfterCreate: Bool = true
    @State private var isPresentingPathNotice = false
    @State private var isPresentingOverwriteConfirm = false
    @State private var overwriteDestinationName = ""
    @State private var isPresentingWorkbookIssue = false

    /// Deliberately doesn't check for a folder here -- `create()` explains that with its own alert.
    private var canCreate: Bool {
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if importFromWorkbook, workbookURL == nil { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New Project")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(16)

            Divider().background(Color(hex: "#242429"))

            VStack(alignment: .leading, spacing: 18) {
                field("Project Name") {
                    TextField("Untitled Project", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }

                field("Path") {
                    VStack(alignment: .leading, spacing: 4) {
                        pathRow(
                            url: projectFolderURL,
                            placeholder: "No folder selected",
                            isEnabled: true,
                            browse: browseForFolder
                        )
                        Text("The project saves here as a .dbdj file and keeps itself up to date.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#71717a"))
                    }
                }

                Divider().background(Color(hex: "#242429"))

                VStack(alignment: .leading, spacing: 10) {
                    Text("OPTIONAL: IMPORT FROM DANCEBREAK DJ WORKBOOK")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white)
                        .tracking(0.5)

                    Toggle("Import songs from a workbook", isOn: $importFromWorkbook)
                        .toggleStyle(.switch)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(importFromWorkbook ? .white : Color(hex: "#52525b"))
                        .pointingHandCursor()

                    pathRow(
                        url: workbookURL,
                        placeholder: "No workbook selected",
                        isEnabled: importFromWorkbook,
                        browse: browseForWorkbook
                    )
                    .opacity(importFromWorkbook ? 1 : 0.4)
                }

                Divider().background(Color(hex: "#242429"))

                Toggle("Run tutorial after creating", isOn: $runTutorialAfterCreate)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .pointingHandCursor()
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            HStack {
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                    .pointingHandCursor()

                Spacer()

                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
                    // Stays clickable with no path so `create()` can explain why via alert, but greyed out so it doesn't look ready.
                    .tint(projectFolderURL == nil ? Color(hex: "#3f3f46") : Color.accentColor)
                    .disabled(!canCreate)
                    .pointingHandCursor()
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(Color(hex: "#0e0e10"))
        .alert("No Path Selected", isPresented: $isPresentingPathNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Select a path and then try again.")
        }
        .alert("No Songs Found", isPresented: $isPresentingWorkbookIssue) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Couldn't find any recognizable song rows in that workbook. Check that it has \"Song Title\" and \"Artist\" columns, then check the spreadsheet and try again.")
        }
        .alert("Overwrite Existing Project?", isPresented: $isPresentingOverwriteConfirm) {
            Button("Cancel", role: .cancel) {}
            // Deferred a tick -- calling `onDismiss()` (which tears down this whole sheet)
            // synchronously from inside the alert's own action races the alert's dismissal on
            // macOS and can silently drop it, leaving the New Project dialog stuck on screen.
            Button("Overwrite", role: .destructive) {
                DispatchQueue.main.async { proceedWithCreate() }
            }
        } message: {
            Text("\"\(overwriteDestinationName).\(PlayerController.projectFileExtension)\" already exists at this path. Creating this project will overwrite it.")
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            content()
        }
    }

    private func pathRow(url: URL?, placeholder: String, isEnabled: Bool, browse: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button("Browse…", action: browse)
                .buttonStyle(.bordered)
                .disabled(!isEnabled)
                .pointingHandCursor()

            Text(url?.path ?? placeholder)
                .font(.system(size: 11))
                .foregroundColor(url == nil ? Color(hex: "#52525b") : .white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = projectFolderURL
        panel.message = "Choose where the project file should be saved."
        panel.prompt = "Choose"
        if panel.runModal() == .OK { projectFolderURL = panel.url }
    }

    private func browseForWorkbook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "xlsx")!]
        panel.message = "Choose a Dancebreak DJ Workbook (CSV or XLSX)"
        panel.prompt = "Choose"
        if panel.runModal() == .OK { workbookURL = panel.url }
    }

    private func create() {
        guard let saveFolderURL = projectFolderURL else {
            isPresentingPathNotice = true
            return
        }

        // Checked here, before the project exists or this dialog dismisses, rather than after
        // `player.createProject` builds an empty project and only then discovers the workbook
        // is bad -- that left the DJ looking at a stuck dialog with no clear way back.
        if importFromWorkbook, let workbookURL, loadWorkbookRows(from: workbookURL).isEmpty {
            isPresentingWorkbookIssue = true
            return
        }

        let sanitizedName = player.sanitizeProjectName(projectName)
        let destinationURL = saveFolderURL
            .appendingPathComponent("\(sanitizedName).\(PlayerController.projectFileExtension)")
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            overwriteDestinationName = sanitizedName
            isPresentingOverwriteConfirm = true
            return
        }

        proceedWithCreate()
    }

    private func proceedWithCreate() {
        guard let saveFolderURL = projectFolderURL else {
            isPresentingPathNotice = true
            return
        }

        onDismiss()
        if runTutorialAfterCreate {
            TutorialManager.shared.scheduleStart(.mainControl)
            // A workbook import shows its own review screen first -- queue that tour too.
            if importFromWorkbook {
                TutorialManager.shared.scheduleStart(.workbookImporter)
            }
            // Queued for whenever the DJ first reaches each of these -- previously missing here,
            // so checking this box didn't bring back the Spotify/YouTube importer tours once
            // they'd already been seen once.
            TutorialManager.shared.scheduleStart(.timingEditor)
            TutorialManager.shared.scheduleStart(.spotifyImporter)
            TutorialManager.shared.scheduleStart(.songImporter)
        } else {
            TutorialManager.shared.markSeen(.mainControl)
        }
        player.createProject(
            named: projectName,
            autosaveFolder: saveFolderURL,
            workbookURL: importFromWorkbook ? workbookURL : nil
        )
    }
}

struct AppLogoView: View {
    private var appIcon: NSImage? {
        return NSApplication.shared.applicationIconImage
    }

    var body: some View {
        Group {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 4)
            } else {
                // Your existing placeholder fallback
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#1f2937"), Color(hex: "#0f172a")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        VStack(spacing: 6) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40, weight: .semibold))
                                .foregroundColor(.white.opacity(0.9))
                            Text("DP")
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    )
                    .shadow(color: .black.opacity(0.24), radius: 10, x: 0, y: 4)
            }
        }
    }
}

// MARK: - PLAYLIST QUEUE
/// Not an `HSplitView`: with both panes flexible it ignores `idealWidth` and always reads as a 50/50 split.
struct QueueSplitView: View {
    @ObservedObject var player: PlayerController

    static let minQueueWidth: CGFloat = 280
    static let dividerWidth: CGFloat = 14
    private static let dragSpace = "queueSplit"
    static let maxQueueWidth: CGFloat = 700
    /// Width the library needs before the queue is allowed to take any more room.
    private static let minLibraryWidth: CGFloat = 380

    @AppStorage("DancePlayer.queueWidth") private var storedQueueWidth: Double = 400

    var body: some View {
        GeometryReader { geo in
            // A narrow window squeezes the queue rather than pushing the library off-screen.
            let ceiling = max(
                Self.minQueueWidth,
                min(Self.maxQueueWidth, geo.size.width - Self.minLibraryWidth - Self.dividerWidth)
            )
            let queueWidth = min(max(CGFloat(storedQueueWidth), Self.minQueueWidth), ceiling)

            HStack(spacing: 0) {
                PlaylistView(player: player)
                    .frame(width: queueWidth)

                divider(ceiling: ceiling)

                LibraryTableView(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .coordinateSpace(name: Self.dragSpace)
        }
        // Deferred a tick: publishing during `onAppear`'s own update pass is undefined behavior (see ContentView's onAppear).
        .onAppear { DispatchQueue.main.async { TutorialManager.shared.startIfNeverSeen(.mainControl) } }
    }

    /// The whole gap is the grab target, since an overlay reaching outside its parent isn't reliably hit-tested.
    private func divider(ceiling: CGFloat) -> some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(hex: "#242429"))
                .frame(width: 1)
        }
        .frame(width: Self.dividerWidth)
        .contentShape(Rectangle())
        .resizeLeftRightCursor()
        .gesture(
            // Absolute cursor x, not translation: translation measured in the divider's own space trailed the cursor as it moved.
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.dragSpace))
                .onChanged { value in
                    player.isDraggingDivider = true
                    let proposed = value.location.x - Self.dividerWidth / 2
                    storedQueueWidth = Double(
                        min(max(proposed, Self.minQueueWidth), ceiling)
                    )
                }
                .onEnded { _ in
                    player.isDraggingDivider = false
                }
        )
    }
}

struct PlaylistView: View {
    @State private var isShowingCursedSongs = false

    @ObservedObject var player: PlayerController
    @State private var draggedTrack: Track? = nil
    @State private var dropTargetTrackID: UUID? = nil
    @State private var lastDropHapticTrackID: UUID? = nil

    /// Command-click toggles one row; shift-click extends from the last row clicked at all, matching Finder rather than just the selection.
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var lastClickedTrackID: UUID? = nil

    @State private var isShowingAddMenu = false
    @State private var isShowingSpotifyImporter = false
    @State private var spotifyImportKind: SpotifyImportKind = .track
    @State private var isShowingYouTubeImporter = false

    @ObservedObject private var tutorialManager = TutorialManager.shared
    @ObservedObject private var tutorialSampleData = TutorialSampleData.shared
    @State private var draggedSampleID: UUID?

    /// Shows sample demo data instead of the (empty, on a brand-new project) real queue while the main control tour runs.
    private var isShowingTutorialSample: Bool {
        tutorialManager.activeContext == .mainControl && player.tracks.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // MARK: - Header Toolbar (Cleaned up)
            HStack {
                Text("LIVE PLAYLIST QUEUE")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .tracking(0.5)
                    .onTapGesture { openCursedSongs() }

                Spacer()
                
                // ADD TRACK BUTTON (Kept here for library management convenience)
                Button(action: {
                    isShowingAddMenu.toggle()
                    if isShowingTutorialSample { TutorialManager.shared.reportAction(.openedAddMenu) }
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .tutorialAnchor("playlist.add")
                .popover(isPresented: $isShowingAddMenu, arrowEdge: .bottom) {
                    AddTrackMenu(
                        onSpotifyTrack: {
                            spotifyImportKind = .track
                            isShowingAddMenu = false
                            isShowingSpotifyImporter = true
                        },
                        onSpotifyPlaylist: {
                            spotifyImportKind = .playlist
                            isShowingAddMenu = false
                            isShowingSpotifyImporter = true
                        },
                        onLocalFiles: {
                            isShowingAddMenu = false
                            player.openFilePicker()
                        },
                        onYouTubeDownload: {
                            isShowingAddMenu = false
                            isShowingYouTubeImporter = true
                        },
                        onPopularEdit: { edit in
                            isShowingAddMenu = false
                            if isShowingTutorialSample {
                                // A real import would add a real track, which would end the
                                // tutorial's sample-data mode outright -- simulated instead, the
                                // same as the rest of this demo.
                                if let spare = tutorialSampleData.spareTrack() {
                                    var simulated = spare
                                    simulated.title = edit.displayName
                                    simulated.artist = "Popular Edit"
                                    simulated.danceStyles = edit.danceStyles
                                    // `spareTrack()` clones the sample it's based on artwork,
                                    // audio and all -- an edit ships its own real, bundled
                                    // recording, so this swaps that back in rather than leaving
                                    // it pointing at (and showing) an unrelated sample's.
                                    if let bundledURL = edit.bundledURL {
                                        simulated.url = bundledURL
                                    }
                                    simulated.artwork = nil
                                    let simulatedID = simulated.id
                                    tutorialSampleData.demoTracks.append(simulated)
                                    Task {
                                        guard let art = await PopularEditArtwork.load(for: edit) else { return }
                                        if let idx = tutorialSampleData.demoTracks.firstIndex(where: { $0.id == simulatedID }) {
                                            tutorialSampleData.demoTracks[idx].artwork = art
                                        }
                                    }
                                }
                            } else {
                                player.importPopularEdit(edit)
                            }
                        },
                        isTutorialMode: isShowingTutorialSample
                    )
                    // The tutorial's floating callout panel is a separate window, so its own
                    // Next click otherwise reads as an outside click and auto-dismisses this --
                    // only this code should ever close it mid-tour.
                    .interactiveDismissDisabled(isShowingTutorialSample)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)
            .tutorialAnchor("playlist.header")

            if !selectedTrackIDs.isEmpty {
                selectionActionBar
            }

            // MARK: - Queue Core Layout
            if isShowingTutorialSample {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(tutorialSampleData.demoTracks.enumerated()), id: \.element.id) { index, track in
                            PlaylistRow(
                                displayIndex: index + 1,
                                track: track,
                                isPlaying: tutorialManager.simulatedNowPlaying?.title == track.title,
                                isImporting: false,
                                isBeingDragged: draggedSampleID == track.id,
                                isDropTarget: false,
                                isSelected: false,
                                onDelete: {
                                    tutorialSampleData.demoTracks.removeAll { $0.id == track.id }
                                    // Later steps (classify, play) need at least one track to
                                    // point at, so deleting the last one brings a fresh one back.
                                    if tutorialSampleData.demoTracks.isEmpty, let spare = tutorialSampleData.spareTrack() {
                                        tutorialSampleData.demoTracks = [spare]
                                    }
                                    TutorialManager.shared.reportAction(.deletedSample)
                                },
                                onToggleSkip: {
                                    if let sampleIndex = tutorialSampleData.demoTracks.firstIndex(where: { $0.id == track.id }) {
                                        tutorialSampleData.demoTracks[sampleIndex].isSkipped.toggle()
                                    }
                                    TutorialManager.shared.reportAction(.hiddenSample)
                                }
                            )
                            .onTapGesture(count: 2) {
                                TutorialManager.shared.playSample(track)
                            }
                            .help("Double-click to play — right-click for Skip/Delete")
                            .onDrag {
                                draggedSampleID = track.id
                                return NSItemProvider(object: track.id.uuidString as NSString)
                            }
                            .onDrop(of: [.text], delegate: SampleReorderDropDelegate(
                                targetID: track.id,
                                sampleTracks: $tutorialSampleData.demoTracks,
                                draggedSampleID: $draggedSampleID
                            ))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .tutorialAnchor("playlist.queue")
            } else if player.tracks.isEmpty {
                VStack(spacing: 8) {
                    Text("Drop audio tracks here")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
                .frame(maxWidth: .infinity, minHeight: 70)
                .background(Color(hex: "#131316"))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .tutorialAnchor("playlist.queue")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(player.tracks) { track in
                            PlaylistRow(
                                displayIndex: player.queueNumber(for: track.id),
                                track: track,
                                isPlaying: player.currentTrack?.id == track.id,
                                isImporting: !player.animationsEnabled,
                                isBeingDragged: draggedTrack?.id == track.id,
                                isDropTarget: dropTargetTrackID == track.id,
                                isSelected: selectedTrackIDs.contains(track.id),
                                onDelete: { deleteSelectionOrSingle(track.id) },
                                onToggleSkip: { toggleSkipSelectionOrSingle(track.id) }
                            )
                                .onTapGesture(count: 2) {
                                    if selectedTrackIDs.isEmpty { player.play(id: track.id) }
                                }
                                .simultaneousGesture(TapGesture(count: 1).onEnded {
                                    handleRowClick(track.id)
                                })
                                .onDrag {
                                    selectedTrackIDs.removeAll()
                                    self.draggedTrack = track
                                    self.dropTargetTrackID = nil
                                    self.lastDropHapticTrackID = nil
                                    return NSItemProvider(object: track.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: PlaylistDropDelegate(
                                    targetTrack: track,
                                    player: player,
                                    draggedTrack: $draggedTrack,
                                    dropTargetTrackID: $dropTargetTrackID,
                                    lastDropHapticTrackID: $lastDropHapticTrackID
                                ))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .onChange(of: draggedTrack?.id) { _, newValue in
                    if newValue == nil {
                        dropTargetTrackID = nil
                        lastDropHapticTrackID = nil
                    }
                }
                .tutorialAnchor("playlist.queue")
            }
        }
        .background(Color(hex: "#09090b"))
        .sheet(isPresented: $isShowingSpotifyImporter) {
            SpotifyImportSheet(player: player, kind: spotifyImportKind)
        }
        .sheet(isPresented: $isShowingYouTubeImporter) {
            YouTubeDownloadImportSheet(player: player)
        }
        .sheet(isPresented: $isShowingCursedSongs) {
            CursedSongsSheet(player: player) { isShowingCursedSongs = false }
        }
        // Leaving the tour mid-flow (Skip, or otherwise) no longer auto-closes the Add Track
        // popover on its own now that outside-click dismissal is disabled during the tour --
        // close it explicitly instead of leaving it stranded open.
        .onChange(of: tutorialManager.activeContext) { oldValue, newValue in
            if oldValue == .mainControl, newValue != .mainControl {
                isShowingAddMenu = false
            }
        }
    }

    private var selectionActionBar: some View {
        let ids = selectedTrackIDs
        let allSkipped = ids.allSatisfy { id in player.tracks.first(where: { $0.id == id })?.isSkipped ?? false }

        return HStack(spacing: 8) {
            Text("\(ids.count) selected")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: "#a3a3ac"))

            Spacer()

            Button(allSkipped ? "Play" : "Skip") {
                player.setSkipped(!allSkipped, forIDs: ids)
                HapticFeedback.perform(.generic)
            }
            .buttonStyle(.bordered)
            .pointingHandCursor()

            Button("Delete", role: .destructive) {
                player.removeTracks(ids: ids)
                selectedTrackIDs.removeAll()
                HapticFeedback.perform(.generic)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .pointingHandCursor()

            Button {
                selectedTrackIDs.removeAll()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "#18181b"))
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color(hex: "#242429")), alignment: .bottom)
    }

    /// Right-click (or the row buttons) acts on the whole selection if the row is in it, otherwise just that track.
    private func deleteSelectionOrSingle(_ id: UUID) {
        if selectedTrackIDs.contains(id) {
            player.removeTracks(ids: selectedTrackIDs)
            selectedTrackIDs.removeAll()
        } else {
            player.removeTrack(id: id)
        }
    }

    private func toggleSkipSelectionOrSingle(_ id: UUID) {
        if selectedTrackIDs.contains(id) {
            let allSkipped = selectedTrackIDs.allSatisfy { sid in player.tracks.first(where: { $0.id == sid })?.isSkipped ?? false }
            player.setSkipped(!allSkipped, forIDs: selectedTrackIDs)
        } else {
            player.toggleSkipTrack(id: id)
        }
    }

    private func handleRowClick(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags

        if modifiers.contains(.shift), let anchor = lastClickedTrackID,
           let anchorIndex = player.tracks.firstIndex(where: { $0.id == anchor }),
           let targetIndex = player.tracks.firstIndex(where: { $0.id == id }) {
            let range = anchorIndex < targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
            selectedTrackIDs.formUnion(player.tracks[range].map(\.id))
            // The anchor deliberately doesn't move, so a further shift-click extends the range instead of restarting it.
            return
        }

        if modifiers.contains(.command) {
            if selectedTrackIDs.contains(id) {
                selectedTrackIDs.remove(id)
            } else {
                selectedTrackIDs.insert(id)
            }
            lastClickedTrackID = id
            return
        }

        // A plain click just clears the selection rather than replacing it, so it can't wipe out a multi-selection on its own.
        if !selectedTrackIDs.isEmpty {
            selectedTrackIDs.removeAll()
        }
        lastClickedTrackID = id
    }

    private func openCursedSongs() {
        HapticFeedback.perform(.levelChange)
        isShowingCursedSongs = true
    }
}

/// Reached by clicking the queue heading. Deliberately not in the Add menu.
struct CursedSongsSheet: View {
    @ObservedObject var player: PlayerController
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .foregroundColor(Color(hex: "#ef4444"))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Cursed Songs")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("You found them. They are not our fault.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#71717a"))
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(CursedSong.allCases) { song in
                        cursedRow(song)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 460)
        .background(Color(hex: "#0e0e10"))
        .preferredColorScheme(.dark)
    }

    private func cursedRow(_ song: CursedSong) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(song.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(song.isInstalled ? .white : Color(hex: "#71717a"))
                Text(song.isInstalled ? song.subtitle : "Audio file not installed yet")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#71717a"))
            }

            Spacer()

            Button("Add") {
                player.importCursedSong(song)
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .pointingHandCursor()
            .disabled(!song.isInstalled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "#18181b"))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#27272a"), lineWidth: 1)
        )
    }
}

struct AddTrackMenu: View {
    let onSpotifyTrack: () -> Void
    let onSpotifyPlaylist: () -> Void
    let onLocalFiles: () -> Void
    let onYouTubeDownload: () -> Void
    let onPopularEdit: (PopularEdit) -> Void
    /// Only true for the tutorial's sample-data mode -- swaps the native `Menu` (which renders
    /// as an AppKit `NSMenu`, entirely outside the SwiftUI view tree the tutorial can measure or
    /// highlight) for a plain SwiftUI popover flyout instead, so "Popular Edits" and its items
    /// can actually be spotlighted.
    var isTutorialMode: Bool = false

    @State private var isShowingPopularEditsFlyout = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onSpotifyTrack) {
                Label("Track from Spotify", systemImage: "music.note")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pointingHandCursor()

            Button(action: onSpotifyPlaylist) {
                Label("Spotify Playlist", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pointingHandCursor()

            Divider()
                .background(Color(hex: "#27272a"))

            Button(action: onLocalFiles) {
                Label("Local Files", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pointingHandCursor()

            Button(action: onYouTubeDownload) {
                Label("Download File", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .pointingHandCursor()
            .help("Search YouTube directly and download the audio -- no Spotify account needed")

            if isTutorialMode {
                Button(action: {
                    isShowingPopularEditsFlyout = true
                    TutorialManager.shared.reportAction(.openedPopularEditsMenu)
                }) {
                    Label("Popular Edits", systemImage: "star")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pointingHandCursor()
                .tutorialAnchor("addmenu.popularEdits")
                .popover(isPresented: $isShowingPopularEditsFlyout, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(PopularEdit.allCases) { edit in
                            Button(edit.displayName) {
                                onPopularEdit(edit)
                                TutorialManager.shared.reportAction(.selectedPopularEdit)
                                isShowingPopularEditsFlyout = false
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#d4d4d8"))
                    .padding(8)
                    .frame(width: 210)
                    .background(Color(hex: "#18181b"))
                    .interactiveDismissDisabled(true)
                    .tutorialAnchor("addmenu.editsList")
                }
            } else {
                Menu {
                    ForEach(PopularEdit.allCases) { edit in
                        Button(edit.displayName) {
                            onPopularEdit(edit)
                        }
                    }
                } label: {
                    Label("Popular Edits", systemImage: "star")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pointingHandCursor()
            }
        }
        // Per row rather than on the stack, or the pointer cursor would apply over the gaps and divider too.
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(Color(hex: "#d4d4d8"))
        .padding(8)
        .frame(width: 210)
        .background(Color(hex: "#18181b"))
    }
}

struct SpotifyImportSheet: View {
    @ObservedObject var player: PlayerController
    let kind: SpotifyImportKind

    @Environment(\.dismiss) private var dismiss
    @AppStorage("spotifyClientID") private var spotifyClientID: String = ""
    @State private var spotifyInput: String = ""
    @State private var isShowingSetupHelp = false

    private var title: String {
        switch kind {
        case .track:
            return "Track from Spotify"
        case .playlist:
            return "Spotify Playlist"
        }
    }

    private var inputPlaceholder: String {
        switch kind {
        case .track:
            return "Artist and song title, URL, URI, or ID"
        case .playlist:
            return "Playlist URL, URI, or ID"
        }
    }

    private var hasInput: Bool {
        !spotifyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var statusColor: Color {
        guard let message = player.spotifyStatusMessage else { return Color(hex: "#a3a3ac") }
        return message.hasPrefix("Imported") || message.hasPrefix("Found") ? Color(hex: "#22c55e") : Color(hex: "#f97316")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("SPOTIFY CLIENT ID")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)

                    Button(action: { isShowingSetupHelp.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "#a3a3ac"))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Spotify setup help")
                    .popover(isPresented: $isShowingSetupHelp, arrowEdge: .top) {
                        SpotifySetupHelpPopover()
                    }
                }

                TextField("Client ID", text: $spotifyClientID)
                    .textFieldStyle(.roundedBorder)
            }
            .tutorialAnchor("spotify.clientID")

            VStack(alignment: .leading, spacing: 5) {
                Text(kind == .track ? "SPOTIFY TRACK" : "SPOTIFY PLAYLIST")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                TextField(inputPlaceholder, text: $spotifyInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitPrimaryAction()
                    }
                if kind == .playlist {
                    Text("This import method only reads the first 100 songs of a playlist.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#f97316"))
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .tutorialAnchor("spotify.input")

            if kind == .track {
                HStack(spacing: 8) {
                    Button(action: searchTracks) {
                        HStack(spacing: 6) {
                            if player.isSpotifySearching {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "magnifyingglass")
                            }
                            Text(player.isSpotifySearching ? "Searching" : "Search")
                        }
                    }
                    .buttonStyle(DisplayWindowButtonStyle())
                    .pointingHandCursor()
                    .disabled(player.isSpotifySearching || player.isSpotifyImporting || !hasInput)

                    Button(action: importInput) {
                        HStack(spacing: 6) {
                            if player.isSpotifyImporting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "link.badge.plus")
                            }
                            Text(player.isSpotifyImporting ? "Importing" : "Import URL")
                        }
                    }
                    .buttonStyle(DisplayWindowButtonStyle())
                    .pointingHandCursor()
                    .disabled(player.isSpotifyImporting || player.isSpotifySearching || !hasInput)
                }
                .tutorialAnchor("spotify.actions")
            }

            if kind == .track && !player.spotifySearchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(player.spotifySearchResults) { track in
                            SpotifySearchResultRow(track: track) {
                                player.importSpotifyTrack(track)
                            }
                        }
                    }
                }
                .frame(maxHeight: 230)
                .background(Color(hex: "#0c0c0e"))
                .cornerRadius(6)
            }

            if let message = player.spotifyStatusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()

                if kind == .playlist {
                    Button(action: importInput) {
                        HStack(spacing: 6) {
                            if player.isSpotifyImporting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "plus")
                            }
                            Text(player.isSpotifyImporting ? "Importing" : "Import")
                        }
                    }
                    .buttonStyle(DisplayWindowButtonStyle())
                    .pointingHandCursor()
                    .disabled(player.isSpotifyImporting || !hasInput)
                    .tutorialAnchor("spotify.actions")
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
        .tutorialOverlayHost(for: [.spotifyImporter])
        .onAppear {
            player.isSpotifyImportSheetPresented = true
            DispatchQueue.main.async { TutorialManager.shared.startIfNeverSeen(.spotifyImporter) }
        }
        .onDisappear {
            player.isSpotifyImportSheetPresented = false
            player.spotifySearchResults = []
        }
    }

    private func submitPrimaryAction() {
        if kind == .playlist {
            importInput()
        } else {
            if isSpotifyPlaylistInput(spotifyInput) {
                player.spotifySearchResults = []
                player.importSpotify(input: spotifyInput, kind: .playlist, clientID: spotifyClientID)
            } else if isInputDirectLinkOrID(spotifyInput) {
                player.spotifySearchResults = []
                importInput()
            } else {
                searchTracks()
            }
        }
    }

    private func isInputDirectLinkOrID(_ input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        if cleaned.contains("spotify.com") || cleaned.hasPrefix("spotify:") {
            return true
        }
        
        let idRegex = "^[a-zA-Z0-9]{22}$"
        if cleaned.range(of: idRegex, options: .regularExpression) != nil {
            return true
        }
        
        return false
    }

    private func isSpotifyPlaylistInput(_ input: String) -> Bool {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if cleaned.hasPrefix("spotify:playlist:") {
            return true
        }

        if cleaned.contains("spotify.com") {
            return cleaned.contains("/playlist/")
        }

        return false
    }

    private func searchTracks() {
        player.searchSpotifyTracks(query: spotifyInput, clientID: spotifyClientID)
    }

    private func importInput() {
        player.importSpotify(input: spotifyInput, kind: kind, clientID: spotifyClientID)
    }
}

/// A plain YouTube search-and-download, with no Spotify account or client ID involved.
struct YouTubeDownloadImportSheet: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery: String = ""

    private var statusColor: Color {
        guard let message = player.youTubeDownloadStatusMessage else { return Color(hex: "#a3a3ac") }
        return message.hasPrefix("Downloaded") ? Color(hex: "#22c55e") : Color(hex: "#f97316")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Download File")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }

            Text("Paste a YouTube video title or type a song name, pick the right match, and "
                 + "its audio is downloaded from YouTube with the title, artist, and cover art "
                 + "from iTunes. No Spotify account or API key needed.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#a3a3ac"))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("SEARCH")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                HStack(spacing: 8) {
                    TextField("e.g. \"Adele - Hello (Official Music Video)\"", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(search)

                    Button(action: search) {
                        if player.isSearchingITunes {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                    }
                    .buttonStyle(DisplayWindowButtonStyle())
                    .pointingHandCursor()
                    .disabled(player.isSearchingITunes || searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .tutorialAnchor("song.search")

            if !player.iTunesSearchResults.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(player.iTunesSearchResults) { result in
                            ITunesSearchResultRow(
                                result: result,
                                isDownloading: player.isDownloadingFromYouTube
                            ) {
                                player.importFromYouTube(
                                    artist: result.artistName,
                                    title: result.trackName,
                                    expectedDurationSeconds: result.durationSeconds,
                                    artworkURL: result.artworkURL
                                )
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(Color(hex: "#0c0c0e"))
                .cornerRadius(6)
                .tutorialAnchor("song.results")
            }

            if let message = player.youTubeDownloadStatusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
        .tutorialOverlayHost(for: [.songImporter])
        .onAppear {
            player.isYouTubeDownloadSheetPresented = true
            DispatchQueue.main.async { TutorialManager.shared.startIfNeverSeen(.songImporter) }
        }
        .onDisappear {
            player.isYouTubeDownloadSheetPresented = false
            player.youTubeDownloadStatusMessage = nil
            player.iTunesSearchResults = []
        }
    }

    private func search() {
        let cleaned = PlayerController.cleanedYouTubeStyleTitle(searchQuery)
        guard !cleaned.isEmpty else { return }
        player.searchITunes(query: cleaned)
    }
}

struct ITunesSearchResultRow: View {
    let result: PlayerController.ITunesSearchResult
    let isDownloading: Bool
    let onImport: () -> Void

    private var durationLabel: String {
        guard let seconds = result.durationSeconds else { return "" }
        return String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: result.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: "#71717a"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 40, height: 40)
            .background(Color(hex: "#18181b"))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(result.trackName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(result.artistName)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !durationLabel.isEmpty {
                Text(durationLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(hex: "#71717a"))
            }

            Button(action: onImport) {
                if isDownloading {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .buttonStyle(DisplayWindowButtonStyle())
            .pointingHandCursor()
            .disabled(isDownloading)
            .help("Download this match")
        }
        .padding(8)
        .background(Color(hex: "#18181b"))
        .cornerRadius(6)
    }
}

struct SpotifySearchResultRow: View {
    let track: Track
    let onImport: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let artwork = track.artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color(hex: "#71717a"))
                }
            }
            .frame(width: 42, height: 42)
            .background(Color(hex: "#18181b"))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onImport) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(DisplayWindowButtonStyle())
            .pointingHandCursor()
            .help("Import track")
        }
        .padding(8)
        .background(Color(hex: "#18181b"))
        .cornerRadius(6)
    }
}



// MARK: - Set Clock

/// Sits in the top bar as text, not a window; shows a configure button until set, then the projected finish and how far off target it is.
struct SetClockBar: View {
    @ObservedObject var player: PlayerController
    @Binding var isPresentingConfigure: Bool

    var body: some View {
        Group {
            if player.isSetClockConfigured {
                Button(action: { isPresentingConfigure = true }) {
                    // Falls back to just the clock icon rather than squeezing this text into a single-letter-per-line column.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                            Text(readout).fixedSize()
                            if let delta = player.setClockDeltaSeconds {
                                Text(deltaLabel(delta))
                                    .fixedSize()
                                    .foregroundColor(deltaColor(delta))
                            }
                        }
                        Image(systemName: "clock")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help("\(readout) — click to reconfigure")
            } else {
                Button(action: { isPresentingConfigure = true }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                            Text("Configure Set Clock").fixedSize()
                        }
                        Image(systemName: "clock")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help("Configure Set Clock")
            }
        }
        .popover(isPresented: $isPresentingConfigure, arrowEdge: .bottom) {
            SetClockConfigureView(player: player) { isPresentingConfigure = false }
        }
    }

    private var readout: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "Ends \(formatter.string(from: player.setClockProjectedEnd))"
    }

    private func deltaLabel(_ delta: Double) -> String {
        let minutes = Int((abs(delta) / 60).rounded())
        if minutes == 0 { return "on time" }
        return delta > 0 ? "+\(minutes)m over" : "\(minutes)m spare"
    }

    /// Keyed off the same rounding as `deltaLabel` so "+1m over" can't read as green.
    private func deltaColor(_ delta: Double) -> Color {
        let minutes = Int((abs(delta) / 60).rounded())
        let isOver = delta > 0 && minutes > 0
        return isOver ? Color(hex: "#dc2626") : Color(hex: "#3f8f4f")
    }
}

struct SetClockConfigureView: View {
    @ObservedObject var player: PlayerController
    var onDismiss: () -> Void

    @State private var endTime = Date()
    @State private var pauseText = "10"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Clock")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)

            DatePicker(
                "Set ends at",
                selection: $endTime,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.stepperField)

            HStack(spacing: 8) {
                Text("Pause between songs")
                    .font(.system(size: 12))
                Spacer()
                TextField("10", text: $pauseText)
                    .frame(width: 48)
                    .multilineTextAlignment(.trailing)
                Text("sec")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
            }

            Divider().background(Color(hex: "#242429"))

            VStack(alignment: .leading, spacing: 3) {
                Text("ALSO BUDGETED AUTOMATICALLY")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "#52525b"))
                    .tracking(0.6)
                Text("+4 min for every jam")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                Text("+1:30 for every mixer")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
            }

            HStack {
                if player.isSetClockConfigured {
                    Button("Turn Off") {
                        player.setClockEndTime = nil
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                }
                Spacer()
                Button("Start Clock") {
                    player.setClockPauseSeconds = max(0, Double(pauseText) ?? 10)
                    // Taken as picked — the quarter hour is only the starting suggestion.
                    player.setClockEndTime = endTime
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            let suggested = player.setClockEndTime ?? Date().addingTimeInterval(2 * 60 * 60)
            endTime = Self.roundedToQuarterHour(suggested)
            pauseText = String(Int(player.setClockPauseSeconds))
        }
    }

    /// Rounds only the initial suggestion; safe because every real UTC offset is a multiple of 15 minutes.
    static func roundedToQuarterHour(_ date: Date) -> Date {
        let quarter = 15.0 * 60.0
        let snapped = (date.timeIntervalSinceReferenceDate / quarter).rounded() * quarter
        return Date(timeIntervalSinceReferenceDate: snapped)
    }
}

// MARK: - Cover Art Picker Window

/// Walks the set one song at a time, prefetching the next song's candidates so advancing is instant.
struct CoverArtPickerView: View {
    @ObservedObject var player: PlayerController

    @State private var index = 0
    /// Fetched candidates per track id. Doubles as the prefetch cache.
    @State private var cache: [UUID: [ITunesArtworkCandidate]] = [:]
    @State private var loadingIDs: Set<UUID> = []

    private var songs: [Track] { player.tracks }
    private var track: Track? { songs.indices.contains(index) ? songs[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))

            if let track {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        currentSong(track)
                        choices(for: track)
                    }
                    .padding(16)
                }
                Divider().background(Color(hex: "#242429"))
                controls
            } else {
                Text("No songs in this project.")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#71717a"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
        .onAppear { prime() }
        .onChange(of: index) { _, _ in prime() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cover Art")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Text("Song \(min(index + 1, max(songs.count, 1))) of \(songs.count)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
            }
            Spacer()
            Button("Close") { player.closeCoverArtWindow() }
                .buttonStyle(.bordered)
                .pointingHandCursor()
        }
        .padding(16)
    }

    private func currentSong(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = track.artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20))
                        .foregroundColor(Color(hex: "#71717a"))
                }
            }
            .frame(width: 72, height: 72)
            .background(Color(hex: "#18181b"))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("Current: \(resolutionLabel(for: track))")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#52525b"))
                    if track.hasCustomArtwork {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#3f8f4f"))
                            .help("Saved into the project")
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func choices(for track: Track) -> some View {
        if let found = cache[track.id] {
            if found.isEmpty {
                Text("No matches on iTunes for this song.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#52525b"))
                    .frame(height: 120, alignment: .topLeading)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(found) { choice in
                        Button {
                            player.applyChosenArtwork(choice.image, toTrackID: track.id)
                            advance()
                        } label: {
                            VStack(spacing: 5) {
                                Image(nsImage: choice.image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(choice.albumName.isEmpty ? choice.trackName : choice.albumName)
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "#a3a3ac"))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Text(choice.resolutionLabel)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(Color(hex: "#52525b"))
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help("Use this cover for \(track.title)")
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching iTunes…")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
            }
            .frame(height: 120, alignment: .topLeading)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Back") { index = max(0, index - 1) }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(index == 0)

            Button("Skip This Song") { advance() }
                .buttonStyle(.bordered)
                .pointingHandCursor()

            Spacer()

            Text(index + 1 >= songs.count ? "Last song" : "")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#52525b"))
        }
        .padding(16)
    }

    private func resolutionLabel(for track: Track) -> String {
        guard let size = track.artwork?.pixelDimensions else { return "no art" }
        return "\(size.width)×\(size.height)"
    }

    private func advance() {
        if index + 1 < songs.count {
            index += 1
        } else {
            player.closeCoverArtWindow()
        }
    }

    /// Loads the current song and warms the next one, so the next step is already populated.
    private func prime() {
        guard songs.indices.contains(index) else { return }
        load(songs[index])
        if songs.indices.contains(index + 1) { load(songs[index + 1]) }
    }

    private func load(_ track: Track) {
        guard cache[track.id] == nil, !loadingIDs.contains(track.id) else { return }
        loadingIDs.insert(track.id)

        Task {
            let found = await ITunesArtworkLookup.candidates(title: track.title, artist: track.artist)
            await MainActor.run {
                cache[track.id] = found
                loadingIDs.remove(track.id)
            }
        }
    }
}

struct SpotifySetupHelpPopover: View {
    private let redirectURI = "http://127.0.0.1:43879/callback"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify Setup")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Go to developer.spotify.com/dashboard.")
                Text("2. Create an app, or open an existing app.")
                Text("3. Add this Redirect URI:")
                Text(redirectURI)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "#09090b"))
                    .cornerRadius(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#27272a"), lineWidth: 1))
                Text("4. Copy the app's Client ID and paste it here.")
            }
            .font(.system(size: 12))
            .foregroundColor(Color(hex: "#d4d4d8"))

            Text("You must have Spotify Premium to import files from Spotify. If you don't have premium and are part of Dancebreak, talk to the admin team about this!")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#a3a3ac"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 300)
        .background(Color(hex: "#18181b"))
    }
}

struct PlaylistRow: View {
    let displayIndex: Int?
    let track: Track
    let isPlaying: Bool
    let isImporting: Bool
    var isBeingDragged: Bool = false
    var isDropTarget: Bool = false
    var isSelected: Bool = false
    let onDelete: () -> Void
    let onToggleSkip: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if track.isSkipped {
                Image(systemName: "x.circle")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6b6b75"))
                    .frame(width: 16)
            } else if isPlaying {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#3478f6"))
                    .frame(width: 16)
            } else {
                Text("\(displayIndex ?? 0).")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#44444a"))
                    .frame(width: 16, alignment: .leading)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: track.title, font: .system(size: 11, weight: isPlaying ? .bold : .medium), color: isPlaying ? .white : Color(hex: "#a3a3ac"), isEnabled: !isImporting)
                MarqueeText(text: track.artist, font: .system(size: 9), color: Color(hex: "#6b6b75"), isEnabled: !isImporting)
            }
            
            Spacer()
            
            if !track.formattedStylesDisplay.isEmpty && track.formattedStylesDisplay != "—" {
                Text(track.formattedStylesDisplay)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color(hex: "#71717a"))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#1c1c22"))
                    .cornerRadius(3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isDropTarget ? Color(hex: "#1c2f52") : (isSelected ? Color(hex: "#20304f") : (isPlaying ? Color(hex: "#142844") : Color(hex: "#131316"))))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected ? Color(hex: "#3478f6") : (isDropTarget ? Color(hex: "#60a5fa") : (isHovering ? Color.gray.opacity(0.2) : Color.clear)), lineWidth: isSelected ? 1.5 : 1)
        )
        .opacity(track.isSkipped ? 0.42 : (isBeingDragged ? 0.35 : 1))
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: track.isSkipped)
        .onHover { hovering in isHovering = hovering }
        .contextMenu {
            Button(track.isSkipped ? "Unskip Track" : "Skip Track") { onToggleSkip() }
            Button("Delete Track", role: .destructive) { onDelete() }
        }
        .grabCursor(isDragging: isBeingDragged)
    }
}

/// A simple two-item swap rather than a full insert-before/after reorder -- good enough for the demo.
struct SampleReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var sampleTracks: [Track]
    @Binding var draggedSampleID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedSampleID = nil }
        guard let draggedSampleID, draggedSampleID != targetID,
              let fromIndex = sampleTracks.firstIndex(where: { $0.id == draggedSampleID }),
              let toIndex = sampleTracks.firstIndex(where: { $0.id == targetID })
        else { return false }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            sampleTracks.swapAt(fromIndex, toIndex)
        }
        TutorialManager.shared.reportAction(.reorderedSample)
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - DRAG AND DROP UTILITY ENVIRONMENT
struct PlaylistDropDelegate: DropDelegate {
    let targetTrack: Track
    let player: PlayerController
    @Binding var draggedTrack: Track?
    @Binding var dropTargetTrackID: UUID?
    @Binding var lastDropHapticTrackID: UUID?

    func performDrop(info: DropInfo) -> Bool {
        defer {
            self.draggedTrack = nil
            self.dropTargetTrackID = nil
            self.lastDropHapticTrackID = nil
        }

        guard let dragged = draggedTrack else { return false }
        return player.reorderTrack(from: dragged.id, before: targetTrack.id)
    }

    func dropEntered(info: DropInfo) {
        guard draggedTrack != nil else { return }
        if dropTargetTrackID != targetTrack.id {
            dropTargetTrackID = targetTrack.id
            if lastDropHapticTrackID != targetTrack.id {
                HapticFeedback.perform(.alignment)
                lastDropHapticTrackID = targetTrack.id
            }
        }
    }

    func dropExited(info: DropInfo) {
        if dropTargetTrackID == targetTrack.id {
            dropTargetTrackID = nil
            lastDropHapticTrackID = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

struct LibraryTableView: View {
    @ObservedObject var player: PlayerController
    @State private var draggedTrack: Track? = nil
    @State private var dropTargetTrackID: UUID? = nil
    @State private var lastDropHapticTrackID: UUID? = nil
    @State private var isShowingAdvancedSettings = false
    /// Measured content width, so a drag preview matches the row it came from.
    @State private var rowWidth: CGFloat = 380

    @ObservedObject private var tutorialManager = TutorialManager.shared
    @ObservedObject private var tutorialSampleData = TutorialSampleData.shared

    private var isShowingTutorialSample: Bool {
        tutorialManager.activeContext == .mainControl && player.tracks.isEmpty
    }

    private func sampleDanceStylesBinding(for trackID: UUID) -> Binding<Set<String>> {
        Binding(
            get: { tutorialSampleData.demoTracks.first { $0.id == trackID }?.danceStyles ?? [] },
            set: { newValue in
                guard let index = tutorialSampleData.demoTracks.firstIndex(where: { $0.id == trackID }) else { return }
                let wasUntagged = tutorialSampleData.demoTracks[index].danceStyles.isEmpty
                tutorialSampleData.demoTracks[index].danceStyles = newValue
                // Whichever song was untagged at this step, not a specific title -- if the DJ
                // deleted the usual one earlier, another song stands in for it instead.
                if wasUntagged, !newValue.isEmpty {
                    TutorialManager.shared.reportAction(.classifiedSample)
                }
            }
        )
    }

    private func sampleCustomStyleBinding(for trackID: UUID) -> Binding<String> {
        Binding(
            get: { tutorialSampleData.demoTracks.first { $0.id == trackID }?.customStyle ?? "" },
            set: { newValue in
                guard let index = tutorialSampleData.demoTracks.firstIndex(where: { $0.id == trackID }) else { return }
                tutorialSampleData.demoTracks[index].customStyle = newValue
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TransportControls(
                    player: player,
                    tutorialSample: isShowingTutorialSample ? tutorialSampleData.demoTracks.first : nil
                )
                    .tutorialAnchor("transport.controls")

                Spacer()

                SetClockBar(player: player, isPresentingConfigure: $player.isPresentingSetClockConfig)
                    .tutorialAnchor("setclock.bar")

                Button(action: { player.openDisplayWindow() }) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Image(systemName: "macwindow")
                            Text("Open Audience Screen").fixedSize()
                        }
                        Image(systemName: "macwindow")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help("Open Audience Screen")
                .tutorialAnchor("audience.button")

                Button(action: {
                    player.isAdvancedSettingsOpen = true
                    isShowingAdvancedSettings = true
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help("Advanced Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "#111114"))

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
                Rectangle().fill(Color(hex: "#1c1c22")).frame(height: 1)
                    .background(
                        // The rows span this same width, so it's what a drag preview should be.
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { rowWidth = geo.size.width }
                                .onChange(of: geo.size.width) { _, width in rowWidth = width }
                        }
                    )

                ScrollView {
                    VStack(spacing: 0) {
                        if isShowingTutorialSample {
                            ForEach(tutorialSampleData.demoTracks) { track in
                                VStack(spacing: 0) {
                                    TrackRow(
                                        player: player,
                                        track: track,
                                        isPlaying: tutorialManager.simulatedNowPlaying?.title == track.title,
                                        isBeingDragged: false,
                                        isDropTarget: false,
                                        danceStylesOverride: sampleDanceStylesBinding(for: track.id),
                                        customStyleOverride: sampleCustomStyleBinding(for: track.id)
                                    )
                                }
                                Rectangle()
                                    .fill(Color(hex: "#71717a"))
                                    .frame(height: 1)
                            }
                        } else if player.tracks.isEmpty {
                            Text("No tracks loaded in.")
                                .font(.system(size: 20))
                                .foregroundColor(Color(hex: "#a3a3ac"))
                                .padding(.top, 40)
                                .padding(.leading, 40)
                        } else {
                            ForEach(player.tracks) { track in
                                // Wrapped because `TrackRow` is a `GridRow` outside its Grid, so a background on it attaches per cell.
                                VStack(spacing: 0) {
                                    TrackRow(
                                        player: player,
                                        track: track,
                                        isPlaying: player.currentTrack?.id == track.id,
                                        isBeingDragged: draggedTrack?.id == track.id,
                                        isDropTarget: dropTargetTrackID == track.id
                                    )
                                }
                                    .onDrag {
                                        self.draggedTrack = track
                                        self.dropTargetTrackID = nil
                                        self.lastDropHapticTrackID = nil
                                        return NSItemProvider(object: track.id.uuidString as NSString)
                                    } preview: {
                                        // The row itself, so the preview can't drift; a GridRow outside its Grid stacks cells like the list does.
                                        VStack(spacing: 0) {
                                            TrackRow(
                                                player: player,
                                                track: track,
                                                isPlaying: player.currentTrack?.id == track.id
                                            )
                                        }
                                        .frame(width: rowWidth)
                                        .background(Color(hex: "#1c2f52"))
                                    }
                                    .onDrop(of: [.text], delegate: PlaylistDropDelegate(
                                        targetTrack: track,
                                        player: player,
                                        draggedTrack: $draggedTrack,
                                        dropTargetTrackID: $dropTargetTrackID,
                                        lastDropHapticTrackID: $lastDropHapticTrackID
                                    ))
                                Rectangle()
                                        .fill(Color(hex: "#71717a"))
                                        .frame(height: 1)
                            }
                        }
                    }
                }
                .onChange(of: draggedTrack?.id) { _, newValue in
                    if newValue == nil {
                        dropTargetTrackID = nil
                        lastDropHapticTrackID = nil
                    }
                }
                .tutorialAnchor("library.rows")
            }

            Group {
                if let simulated = tutorialManager.simulatedNowPlaying {
                    TutorialSimulatedNowPlayingBar(title: simulated.title, artist: simulated.artist)
                } else {
                    PlaybackStatusBar(player: player)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "#111114"))
            .tutorialAnchor("playback.status")
        }
        .background(Color(hex: "#111114"))
        .sheet(isPresented: $isShowingAdvancedSettings) {
            AdvancedSettingsView(player: player)
                .onDisappear { player.isAdvancedSettingsOpen = false }
        }
    }
}

struct TrackRow: View {
    @ObservedObject var player: PlayerController
    let track: Track
    let isPlaying: Bool
    var isBeingDragged: Bool = false
    var isDropTarget: Bool = false
    /// Used only by the tutorial's sample rows, which aren't in `player.tracks` so the default player-lookup binding below would always miss.
    var danceStylesOverride: Binding<Set<String>>? = nil
    var customStyleOverride: Binding<String>? = nil
    @State private var isShowingPicker = false

    private var danceStylesBinding: Binding<Set<String>> {
        danceStylesOverride ?? Binding(
            get: { player.trackIndex(for: track.id).map { player.tracks[$0].danceStyles } ?? [] },
            set: { newValue in
                if let index = player.trackIndex(for: track.id) {
                    player.tracks[index].danceStyles = newValue
                    player.saveTrack(player.tracks[index])
                }
            }
        )
    }

    private var customStyleBinding: Binding<String> {
        customStyleOverride ?? Binding(
            get: { player.trackIndex(for: track.id).map { player.tracks[$0].customStyle } ?? "" },
            set: { newValue in
                if let index = player.trackIndex(for: track.id) {
                    player.tracks[index].customStyle = newValue
                    player.saveTrack(player.tracks[index])
                }
            }
        )
    }

    var body: some View {
        GridRow {
            // Column 1: Core Track Titles & Timings
            HStack(alignment: .center) {
                HStack(alignment: .center, spacing: 10) {
                    Group {
                        if let artwork = track.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(hex: "#18181b"))
                                .overlay(
                                    Image(systemName: "music.note")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.gray)
                                )
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipped()
                    .cornerRadius(4)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 10) {
                            if isPlaying {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.white)
                            }

                            Text(track.title)
                                .font(.system(size: 15, weight: isPlaying ? .semibold : .regular))
                                .lineLimit(1)
                        }

                        Text(track.artist)
                            .font(.system(size: 15))
                            .foregroundColor(isPlaying ? .white : Color(hex: "#71717a"))
                            .lineLimit(1)
                    }
                }
                
                Spacer(minLength: 16)

                if player.showTempo {
                    Text(track.manualBPM.isEmpty ? "-- BPM" : "\(track.displayedBPM) BPM")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(track.manualBPM.isEmpty ? Color(hex: "#52525b") : Color(hex: "#3478f6"))
                        .padding(.trailing, 12)
                        .help("Double-click to set this track's tempo")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            player.openTimingEditor(for: track.id)
                        }
                        .pointingHandCursor()
                }

                Text(formatDuration(track.effectiveArrangedDuration))
                    .font(.system(size: 15))
                    .foregroundColor(isPlaying ? .white : Color(hex: "#71717a"))
            }
            .contentShape(Rectangle())

            // Column 2: Full-Width Dance Style Box Action Box
            Button(action: { isShowingPicker.toggle() }) {
                HStack {
                    Text(
                        track.formattedStylesDisplay == "—"
                        ? "Select Style"
                        : track.formattedStylesDisplay
                    )
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color(hex: "#18181b"))
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .frame(maxWidth: .infinity)
            .popover(isPresented: $isShowingPicker, arrowEdge: .trailing) {
                DanceStyleMultiSelectorPopover(danceStyles: danceStylesBinding, customStyle: customStyleBinding)
            }

            // Column 3: Track Editor (Styled like Calculate ReplayGain & Formatted Left)
            HStack {
                Button(action: {
                    player.openTimingEditor(for: track.id)
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: track.source == .spotify ? "clock" : "slider.horizontal.3")
                        Text("Track Editor")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help(track.source == .spotify ? "Set Spotify start and end timestamps." : "Edit this track's metadata, timing, fades, and tempo.")

                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            // The system's drag-preview snapshot uses this exact background, so force it opaque during the drag.
            isBeingDragged ? Color(hex: "#111114") :
                (isDropTarget ? Color(hex: "#1c2f52") : (isPlaying ? Color(hex: "#142844") : Color.clear))
        )
        .overlay(
            Rectangle()
                .stroke(isDropTarget ? Color(hex: "#60a5fa") : Color.clear, lineWidth: 1)
        )
        .opacity(isBeingDragged ? 0.35 : 1)
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(count: 2) {
            player.play(id: track.id)
        }
        .pointingHandCursor()
    }

    func formatDuration(_ t: TimeInterval) -> String {
        guard t > 0 else { return "—" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct DanceStyleMultiSelectorPopover: View {
    @Binding var danceStyles: Set<String>
    @Binding var customStyle: String
    @State private var searchText: String = ""

    private static let styleAbbreviations: [String: [String]] = [
        "Night Club Two Step": ["nc2s", "ncts"],
        "West Coast Swing": ["wcs"],
        "Last West Coast Swing": ["lwcs"],
        "Cross-Step Waltz": ["xstep"]
    ]

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredStyles: [String] {
        let trimmed = trimmedSearchText
        guard !trimmed.isEmpty else { return predefinedDanceStyles }

        return predefinedDanceStyles.filter { style in
            if style.localizedCaseInsensitiveContains(trimmed) { return true }
            if let abbreviations = Self.styleAbbreviations[style] {
                return abbreviations.contains { $0.lowercased().hasPrefix(trimmed.lowercased()) }
            }
            return false
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Select Dance Styles")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.gray)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                
                TextField("Search styles...", text: $searchText)
                    .font(.system(size: 11))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(hex: "#09090b"))
            .cornerRadius(4)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#27272a"), lineWidth: 1))
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            
            Divider().background(Color(hex: "#27272a"))
            
            ScrollView {
                VStack(spacing: 2) {
                    if filteredStyles.isEmpty {
                        if !trimmedSearchText.isEmpty {
                            HStack {
                                Image(systemName: "plus.square")
                                    .foregroundColor(.blue)
                                Text("Use \"\(trimmedSearchText)\" as custom style")
                                    .font(.system(size: 12))
                                    .foregroundColor(.blue)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                useSearchTextAsCustomStyle(trimmedSearchText)
                            }
                            .pointingHandCursor()
                            .padding(.top, 8)
                        } else {
                            Text("No styles match your filter")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)
                                .padding(.top, 20)
                                .padding(.leading, 40)
                        }
                    } else {
                        ForEach(filteredStyles, id: \.self) { style in
                            HStack {
                                Image(systemName: isStyleSelected(style) ? "checkmark.square.fill" : "square")
                                    .foregroundColor(isStyleSelected(style) ? .blue : .gray)
                                Text(style)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleStyleSelection(style)
                            }
                            .pointingHandCursor()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 280)
            
            if isStyleSelected("Other") {
                Divider().background(Color(hex: "#27272a"))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Style Designation:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                    TextField("Type custom style...", text: $customStyle)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                }
                .padding(10)
                .background(Color(hex: "#09090b"))
            }
        }
        .frame(width: 210)
        .background(Color(hex: "#18181b"))
    }

    private func isStyleSelected(_ style: String) -> Bool {
        danceStyles.contains(style)
    }

    private func toggleStyleSelection(_ style: String) {
        if danceStyles.contains(style) {
            danceStyles.remove(style)
        } else {
            danceStyles.insert(style)
        }
    }

    /// Files the typed text under "Other" when nothing predefined matches what the DJ typed.
    private func useSearchTextAsCustomStyle(_ text: String) {
        danceStyles.insert("Other")
        customStyle = text
        searchText = ""
    }
}

struct PlaybackStatusBar: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let artwork = player.currentTrack?.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(hex: "#1c1c22")
                            Image(systemName: "music.note")
                                .font(.system(size: 16))
                                .foregroundColor(Color(hex: "#44444a"))
                        }
                    }
                }
                .frame(width: 44, height: 44)
                .cornerRadius(4)
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(hex: "#2e2e38"), lineWidth: 1))
                .help("Click to change the displayed artwork")
                .onTapGesture {
                    player.importArtworkForCurrentTrack()
                }
                .pointingHandCursor()

                VStack(alignment: .leading, spacing: 2) {
                    if let last = player.lastTrack {
                        MarqueeText(
                            text: "LAST PLAYED: \(last.title) — \(last.artist) - \(last.formattedStylesDisplay)",
                            font: .system(size: 15, weight: .bold),
                            color: Color(hex: "#5b34f6"),
                            isEnabled: player.animationsEnabled
                        )
                    }
                    HStack(spacing: 6) {
                        // Suppressed during the pivot call, or run together with the status line it'd read as "...a Cross-Step Waltz Pivots".
                        if player.isBetweenSongs, !player.isShowingPivots {
                            MarqueeText(
                                text: (player.currentTrack?.nextSongLeadIn ?? "The next song is a") + " " + (player.currentTrack?.formattedStylesDisplay ?? "-"),
                                font: .system(size: 30, weight: .bold),
                                color: Color(hex: "#eab308"),
                                isEnabled: player.animationsEnabled
                            )
                        }
                        statusDisplayView
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(statusDisplayColor)
                    }

                    // Shown whenever the cued dance has an intro; announcing one is the DJ's call, not something a countdown implies.
                    if player.isBetweenSongs,
                       !player.isShowingPivots,
                       let cued = player.currentTrack,
                       PlayerController.introURL(for: cued) != nil {
                        HStack(spacing: 8) {
                            Button(player.isPlayingIntro ? "Stop Intro" : "Play Intro") {
                                player.playIntro(for: cued)
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: player.isPlayingIntro ? "#dc2626" : "#7c3aed"))
                            .cornerRadius(4)
                            .pointingHandCursor()
                        }
                    }

                    if player.autoplayCountdownActive {
                        HStack(spacing: 8) {
                            Text("Next song in \(Int(player.autoplayCountdownRemaining.rounded(.up)))s")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                                .monospacedDigit()

                            ProgressView(value: player.autoplayCountdownRemaining, total: max(1, player.autoplayDelaySeconds))
                                .progressViewStyle(.linear)
                                .tint(Color(hex: "#eab308"))
                                .frame(width: 120)

                            Button("Abort Auto-Play") {
                                player.pauseAutoplayCountdown()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "#dc2626"))
                            .cornerRadius(4)
                            .pointingHandCursor()

                            // The other half of the choice: lets the countdown be cut short without going back to the transport.
                            Button("Start Next Song") {
                                player.togglePlayPause()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(hex: "#16a34a"))
                            .cornerRadius(4)
                            .pointingHandCursor()
                        }
                    }
                }
                Spacer()
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            
            Slider(value: Binding(
                get: { player.currentTime },
                set: { newValue in
                    player.currentTime = newValue
                    if !player.isDraggingSlider { player.seek(to: newValue) }
                }
            ), in: 0...max(1, player.duration), onEditingChanged: { dragging in
                player.isDraggingSlider = dragging
                if !dragging {
                    HapticFeedback.perform(.levelChange)
                    player.seek(to: player.currentTime)
                }
            })
            .accentColor(player.isBetweenSongs ? Color(hex: "#eab308") : Color(hex: "#3478f6"))
            .labelsHidden()
        }
    }

    /// Renders at this size when it fits; `minimumScaleFactor` shrinks a long title instead of scrolling it.
    private static let nowPlayingMaxFontSize: CGFloat = 25

    /// A point size rather than a raw scale factor, so changing the max can't move it.
    private static let nowPlayingMinFontSize: CGFloat = 9
    private static var nowPlayingMinScale: CGFloat {
        nowPlayingMinFontSize / nowPlayingMaxFontSize
    }

    @ViewBuilder
    private var statusDisplayView: some View {
        let title = player.currentTrack?.title ?? "Nothing playing"
        let artist = player.currentTrack?.artist ?? ""
        let styles = player.currentTrack?.formattedStylesDisplay ?? "—"

        if player.isShowingPivots {
            // Sized to the next-song line it stands in for, since it's now the only thing on that row.
            Text("Pivots")
                .font(.system(size: 30, weight: .black))
                .lineLimit(1)
        } else if player.isBetweenSongs {
            HStack(spacing: 0) {
            }
        } else if let message = player.spotifyStatusMessage, player.currentTrack?.source == .spotify {
            Text(message)
                .font(.system(size: Self.nowPlayingMaxFontSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(Self.nowPlayingMinScale)
        } else if player.currentTrack?.source == .spotify || player.currentTrack?.source == .local {
            // One concatenated Text, not an HStack, so scale-to-fit applies evenly instead of shrinking each run separately.
            (Text(title).italic() + Text(" - \(artist): \(styles)"))
                .font(.system(size: Self.nowPlayingMaxFontSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(Self.nowPlayingMinScale)
        }
    }

    private var statusDisplayColor: Color {
        if player.isShowingPivots {
            return Color(hex: "#f59e0b")
        }
        if player.spotifyStatusMessage != nil, player.currentTrack?.source == .spotify {
            return Color(hex: "#f97316")
        }

        return player.isBetweenSongs ? Color(hex: "#eab308") : Color(hex: "#3478f6")
    }

    func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct TransportControls: View {
    @ObservedObject var player: PlayerController
    /// Set only during the main control tour on an empty project -- the real queue has nothing
    /// to play, so Play/Pause here drives this sample's own downloaded audio instead.
    var tutorialSample: Track? = nil

    @ObservedObject private var tutorialManager = TutorialManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { if tutorialSample == nil { player.previous() } }) {
                Image(systemName: "backward.end.fill")
                    .foregroundColor(.white)
            }.buttonStyle(TransportButtonStyle())
            .pointingHandCursor()

            Button(action: {
                if let tutorialSample {
                    tutorialManager.toggleSamplePlayback(tutorialSample)
                } else {
                    player.togglePlayPause()
                }
            }) {
                if let tutorialSample {
                    Image(systemName: tutorialManager.isSamplePlaying ? "pause.fill" : "play.fill")
                } else {
                    Image(systemName: player.isBetweenSongs ? "play.circle.fill" : (player.isPlaying ? "pause.fill" : "play.fill"))
                }
            }.buttonStyle(TransportButtonStyle(primary: true))
            .pointingHandCursor()

            Button(action: { if tutorialSample == nil { player.next() } }) {
                Image(systemName: "forward.end.fill")
                    .foregroundColor(.white)
            }.buttonStyle(TransportButtonStyle())
            .pointingHandCursor()
        }
        .padding(3)
        .background(Color(hex: "#09090b"))
        .cornerRadius(6)
    }
}

// MARK: - Native Helpers

extension Text {
    func tableHeader() -> some View {
        self.font(.system(size: 10, weight: .bold)).foregroundColor(Color(hex: "#434348"))
    }
}

struct ScrollingMarquee<Content: View>: View {
    @ViewBuilder var content: () -> Content
    /// Scroll speed in points per second. Lower = slower.
    var speed: CGFloat = 28
    /// Gap between the end of one pass and the start of the next.
    var gap: CGFloat = 48
    /// How long to pause (fully visible at the start) before each pass.
    var pauseDuration: Double = 3
    /// When false, never scrolls -- used to pause the animation while a heavier task (e.g. importing) is running.
    var isEnabled: Bool = true

    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var startDate = Date()

    private var needsScroll: Bool {
        isEnabled && containerWidth > 0 && contentWidth > containerWidth + 0.5
    }

    var body: some View {
        content()
            .lineLimit(1)
            .opacity(needsScroll ? 0 : 1)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, newWidth in containerWidth = newWidth }
                }
            )
            .background(
                content()
                    .lineLimit(1)
                    .fixedSize()
                    .opacity(0)
                    .background(
                        // Measured on change as well as appear, or a view reused for a new song keeps the old width and scrolls wrong.
                        GeometryReader { geo in
                            Color.clear
                                .onAppear {
                                    contentWidth = geo.size.width
                                    startDate = Date()
                                }
                                .onChange(of: geo.size.width) { _, newWidth in
                                    contentWidth = newWidth
                                    startDate = Date()
                                }
                        }
                    )
            )
            .overlay(alignment: .leading) {
                if needsScroll {
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSince(startDate)
                        let cycleDistance = Double(contentWidth + gap)
                        let cycleDuration = max(0.01, cycleDistance / Double(speed)) + pauseDuration
                        let t = elapsed.truncatingRemainder(dividingBy: cycleDuration)
                        let scrollOffset = t < pauseDuration ? 0 : CGFloat(t - pauseDuration) * speed

                        HStack(spacing: gap) {
                            content()
                            content()
                        }
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: -scrollOffset)
                    }
                }
            }
            .clipped()
    }
}

struct MarqueeText: View {
    let text: String
    var font: Font
    var color: Color
    var resetKey: String? = nil
    var isEnabled: Bool = true

    var body: some View {
        ScrollingMarquee(content: {
            Text(text)
                .font(font)
                .foregroundColor(color)
                .lineLimit(1)
        }, isEnabled: isEnabled)
        .id(resetKey ?? text)
    }
}

struct TransportButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: primary ? 15 : 13))
            .foregroundColor(primary ? .white : Color(hex: "#52525b"))
            .frame(width: primary ? 28 : 22, height: 22)
            .background(primary ? Color(hex: "#27272a") : Color.clear)
            .cornerRadius(4)
            .pointingHandCursor()
    }
}

struct DisplayWindowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(Color(hex: "#a3a3ac"))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(hex: "#1c1c22"))
            .cornerRadius(5)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: "#2e2e38"), lineWidth: 1))
            .pointingHandCursor()
    }
}

struct TicklessSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var accentColor: NSColor = .systemBlue
    var onEditingChanged: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> TrackingSlider {
        let slider = TrackingSlider(value: value,
                                    minValue: range.lowerBound,
                                    maxValue: range.upperBound,
                                    target: context.coordinator,
                                    action: #selector(Coordinator.valueChanged(_:)))
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.onEditingChanged = onEditingChanged
        return slider
    }

    func updateNSView(_ nsView: TrackingSlider, context: Context) {
        nsView.doubleValue = value
        nsView.numberOfTickMarks = 0
        nsView.onEditingChanged = onEditingChanged
        context.coordinator.step = step
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, step: step)
    }

    class Coordinator: NSObject {
        var value: Binding<Double>
        var step: Double
        private var lastHapticValue: Double?

        init(value: Binding<Double>, step: Double) {
            self.value = value
            self.step = step
        }

        @objc func valueChanged(_ sender: NSSlider) {
            let snapped = (sender.doubleValue / step).rounded() * step
            if value.wrappedValue != snapped {
                value.wrappedValue = snapped
            }
            if lastHapticValue != snapped {
                HapticFeedback.perform(.levelChange)
                lastHapticValue = snapped
            }
        }
    }

    final class TrackingSlider: NSSlider {
        var onEditingChanged: ((Bool) -> Void)?

        override func mouseDown(with event: NSEvent) {
            onEditingChanged?(true)
            super.mouseDown(with: event)
            onEditingChanged?(false)
        }
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @ObservedObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Advanced Settings")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    tempoSection
                    Divider().background(Color(hex: "#242429"))
                    autoplaySection
                    Divider().background(Color(hex: "#242429"))
                    pivotSection
                    Divider().background(Color(hex: "#242429"))
                    bpmSection
                    Divider().background(Color(hex: "#242429"))
                    coverArtSection
                    Divider().background(Color(hex: "#242429"))
                    spotifySection
                }
                .padding(20)
            }
        }
        .frame(width: 460, height: 620)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
    }

    // MARK: - Tempo Display

    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("TEMPO DISPLAY")

            Toggle("Show Tempo", isOn: $player.showTempo)
                .toggleStyle(.switch)
                .foregroundColor(.white)

            Text("Shows each track's BPM to make tempo changes easier.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
        }
    }

    // MARK: - Tempo Detection

    private var bpmSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("BPM DETECTION")

            Toggle("Detect BPM on import", isOn: $player.bpmDetectionOnImport)
                .toggleStyle(.switch)
                .foregroundColor(.white)

            Text("Estimates each song's tempo from its audio. It's a starting point, not a "
                 + "measurement — check anything the guideline report flags.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
                .fixedSize(horizontal: false, vertical: true)

            Button("Detect BPM for All Songs (⌘T)") { player.detectBPMForLibrary() }
                .buttonStyle(.bordered)
                .pointingHandCursor()
                .disabled(player.tracks.isEmpty || player.isImportingContent)

            if player.isDetectingBPM {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(
                        value: Double(player.bpmDetectionCompleted),
                        total: Double(max(player.bpmDetectionTotal, 1))
                    )
                    .progressViewStyle(.linear)
                    .frame(width: 240)

                    Text("Analysing \(player.bpmDetectionCompleted) of \(player.bpmDetectionTotal) songs…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
            }
        }
    }

    // MARK: - Pivots

    private var pivotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Pivot Screen After A Jam", isOn: $player.pivotScreenEnabled)
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            Text("When a jam finishes, the audience screen calls for pivot partners before the "
                 + "next song is announced, and the booth shows \"Pivots\". Advancing moves on "
                 + "to the next song as usual. Turned off, a jam ends like any other song.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#a3a3ac"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Cover Art

    private var coverArtSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("COVER ART")

            Text("Fetches album art from iTunes at up to \(ITunesArtworkLookup.preferredSize)px, "
                 + "well beyond Spotify's 640px. Reviewed one song at a time so nothing is "
                 + "replaced without you choosing it. Saved into the project, so it only needs "
                 + "the network once.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Cover Art Picker…") { player.openCoverArtWindow() }
                .buttonStyle(.borderedProminent)
                .pointingHandCursor()
                .disabled(player.tracks.isEmpty)

            if player.tracks.isEmpty {
                Text("No songs in this project.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#52525b"))
            } else {
                Text("Also available from the View menu.")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#52525b"))
            }
        }
    }

    // MARK: - Autoplay

    private var autoplaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("AUTOPLAY")

            Toggle("Autoplay Next Song", isOn: $player.autoplayEnabled)
                .toggleStyle(.switch)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Delay before next song")
                        .font(.system(size: 13))
                        .foregroundColor(player.autoplayEnabled ? .white : Color(hex: "#52525b"))
                    Spacer()
                    Text("\(Int(player.autoplayDelaySeconds))s")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(player.autoplayEnabled ? .white : Color(hex: "#52525b"))
                }

                Slider(value: $player.autoplayDelaySeconds, in: 5...30, step: 1)
                    .disabled(!player.autoplayEnabled)
                    .onChange(of: player.autoplayDelaySeconds) { _, _ in
                        HapticFeedback.perform(.levelChange)
                    }
            }

            Text("The in-between-songs screen still shows on the audience display. You can pause the countdown and it'll go straight into the next song when you press play again.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
        }
    }

    // MARK: - Spotify

    private var spotifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("SPOTIFY")

            TextField("Client ID", text: $player.spotifyClientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            Text("Needed to match workbook songs to Spotify and to play Spotify tracks.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(Color(hex: "#71717a"))
            .tracking(0.5)
    }
}
