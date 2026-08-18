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
                    onFinished: { player.pendingWorkbookImport = nil }
                )
            } else if player.hasLoadedProject {
                QueueSplitView(player: player)
                    .disabled(player.isImportingContent)

                if player.selectedTrackForEditing != nil {
                    Color.black.opacity(0.4)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                player.selectedTrackForEditing = nil
                            }
                        }

                    HStack {
                        Spacer()
                        MetadataEditorPanel(player: player)
                            .frame(width: 320)
                            .transition(.move(edge: .trailing))
                    }
                }
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
        }
        .background(Color(hex: "#0e0e10"))
        .preferredColorScheme(.dark)
        .animation(
            player.animationsEnabled ? .easeInOut(duration: 0.2) : nil,
            value: player.selectedTrackForEditing
        )
        .animation(.easeInOut(duration: 0.15), value: player.isImportingContent)
        .navigationTitle(player.projectName)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .inactive || newPhase == .background {
                player.saveProjectOnCloseIfNeeded()
            }
        }
        // A .dbdj can arrive before this view exists, so also check on appear.
        // Deferred a tick: SwiftUI runs these hooks inside its update pass, where publishing is undefined behavior.
        .onAppear {
            DispatchQueue.main.async {
                consumePendingProjectFile(openRequest.pending)
                player.relevelLibraryGainOnLaunch()
            }
        }
        // Closing the window leaves the app running, so save and unload here rather than
        // waiting for a quit that may never come.
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
    }

    /// Takes the URL from the request, not the published property, which still holds its old
    /// value while subscribers run. Deduped by id so it can't open twice.
    private func consumePendingProjectFile(_ request: ProjectFileOpenRequest.Request?) {
        guard let request, request.id != handledProjectRequestID else { return }
        handledProjectRequestID = request.id
        player.openProjectFile(at: request.url)
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
                    Text("Created by Samuel Desai. Special thanks to Akshay Srivatsan, Rehman Hassan, Wally Niu, and Joseph Lucero for input.")
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
    /// Chosen by the DJ via Browse. Autosave is always on, so this is simply where the
    /// project's .dbdj lives.
    @State private var projectFolderURL: URL? = nil
    @State private var importFromWorkbook: Bool = false
    @State private var workbookURL: URL? = nil

    private var canCreate: Bool {
        guard !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if projectFolderURL == nil { return false }
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
                    .disabled(!canCreate)
                    .pointingHandCursor()
            }
            .padding(16)
        }
        .frame(width: 460)
        .background(Color(hex: "#0e0e10"))
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
        guard let saveFolderURL = projectFolderURL else { return }

        onDismiss()
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
    }

    /// The whole gap is the grab target; an overlay reaching outside its parent isn't reliably
    /// hit-tested, so the hairline alone used to catch the cursor.
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
            // Absolute cursor x, not translation: the divider moves as it's dragged, so a
            // translation measured in its own space fed back and trailed the cursor.
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

    /// Command-click toggles one row; shift-click extends from the last row that was clicked at
    /// all, matching Finder rather than the narrower "last row added to the selection" — a
    /// shift-click right after a plain click should extend from that plain click.
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var lastClickedTrackID: UUID? = nil

    @State private var isShowingAddMenu = false
    @State private var isShowingSpotifyImporter = false
    @State private var spotifyImportKind: SpotifyImportKind = .track

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
                Button(action: { isShowingAddMenu.toggle() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
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
                        onPopularEdit: { edit in
                            isShowingAddMenu = false
                            player.importPopularEdit(edit)
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if !selectedTrackIDs.isEmpty {
                selectionActionBar
            }

            // MARK: - Queue Core Layout
            if player.tracks.isEmpty {
                VStack(spacing: 8) {
                    Text("Drop audio tracks here")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
                .frame(maxWidth: .infinity, minHeight: 70)
                .background(Color(hex: "#131316"))
                .cornerRadius(6)
                .padding(.horizontal, 12)
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
            }
        }
        .background(Color(hex: "#09090b"))
        .sheet(isPresented: $isShowingSpotifyImporter) {
            SpotifyImportSheet(player: player, kind: spotifyImportKind)
        }
        .sheet(isPresented: $isShowingCursedSongs) {
            CursedSongsSheet(player: player) { isShowingCursedSongs = false }
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

    /// Right-click (or the row buttons) on a row inside the current selection acts on the whole
    /// selection; on a row outside it, only that one track.
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
            // The anchor deliberately doesn't move: a second shift-click further out extends
            // the same range rather than restarting it from where the last one landed.
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

        // A plain click just clears the queue selection rather than replacing it with this one
        // row — the row's own editing behavior lives elsewhere (TrackRow), so a mode-less
        // single click here would make it impossible to click a row without losing a
        // multi-selection made a moment earlier.
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
    let onPopularEdit: (PopularEdit) -> Void

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
        // Per row rather than on the stack: the style applies to the whole menu, but a cursor
        // applied here would turn to a pointer over the gaps and the divider too.
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
                }
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
        .onDisappear {
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

/// Sits in the top bar as text, not a window. Unconfigured it offers the configure button in
/// its own place; once set it shows the projected finish and how far off target that is.
struct SetClockBar: View {
    @ObservedObject var player: PlayerController
    @Binding var isPresentingConfigure: Bool

    var body: some View {
        Group {
            if player.isSetClockConfigured {
                Button(action: { isPresentingConfigure = true }) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                        Text(readout)
                        if let delta = player.setClockDeltaSeconds {
                            Text(deltaLabel(delta))
                                .foregroundColor(deltaColor(delta))
                        }
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help("Projected finish — click to reconfigure")
            } else {
                Button(action: { isPresentingConfigure = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("Configure Set Clock")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
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

/// Walks the set one song at a time, offering iTunes covers to choose from. Candidates for the
/// next song are fetched while the DJ looks at the current one, so advancing is instant.
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
                Text("Skipped")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "#6b6b75"))
                    .frame(width: 32, alignment: .leading)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TransportControls(player: player)

                Spacer()

                SetClockBar(player: player, isPresentingConfigure: $player.isPresentingSetClockConfig)

                Button(action: { player.openDisplayWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open Audience Screen")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()

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
                        if player.tracks.isEmpty {
                            Text("No tracks loaded in.")
                                .font(.system(size: 20))
                                .foregroundColor(Color(hex: "#a3a3ac"))
                                .padding(.top, 40)
                                .padding(.leading, 40)
                        } else {
                            ForEach(player.tracks) { track in
                                // Wrapped because `TrackRow` is a `GridRow` outside its Grid:
                                // a background on it attaches per cell, not to the whole block.
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
            }

            PlaybackStatusBar(player: player)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "#111114"))
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
    @State private var isShowingPicker = false

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
                    Text(track.manualBPM.isEmpty ? "-- BPM" : "\(track.manualBPM) BPM")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(track.manualBPM.isEmpty ? Color(hex: "#52525b") : Color(hex: "#3478f6"))
                        .padding(.trailing, 12)
                        .help("Double-click to set this track's tempo")
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            player.selectedTrackForEditing = track
                        }
                        .pointingHandCursor()
                }

                Text(formatDuration(track.effectiveDuration))
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
                // Resolved by id on every access — a row's position changes under it whenever
                // the queue is reordered.
                DanceStyleMultiSelectorPopover(
                    danceStyles: Binding(
                        get: {
                            player.trackIndex(for: track.id).map { player.tracks[$0].danceStyles } ?? []
                        },
                        set: { newValue in
                            if let index = player.trackIndex(for: track.id) {
                                player.tracks[index].danceStyles = newValue
                            }
                        }
                    ),
                    customStyle: Binding(
                        get: {
                            player.trackIndex(for: track.id).map { player.tracks[$0].customStyle } ?? ""
                        },
                        set: { newValue in
                            if let index = player.trackIndex(for: track.id) {
                                player.tracks[index].customStyle = newValue
                            }
                        }
                    )
                )
            }

            // Column 3: Edit Metadata (Styled like Calculate ReplayGain & Formatted Left)
            HStack {
                Button(action: {
                    player.selectedTrackForEditing = track
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: track.source == .spotify ? "clock" : "slider.horizontal.3")
                        Text(track.source == .spotify ? "Timing Settings" : "Edit Metadata")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
                .pointingHandCursor()
                .help(track.source == .spotify ? "Set Spotify start and end timestamps." : "Edit local track metadata.")
                
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

struct MetadataEditorPanel: View {
    @ObservedObject var player: PlayerController
    
    // Local ephemeral states for isolated text field operations
    @State private var editableTitle: String = ""
    @State private var editableArtist: String = ""
    
    // Split Minutes and Seconds fields for Truncation
    @State private var startMinString: String = "0"
    @State private var startSecString: String = "00"
    @State private var endMinString: String = "0"
    @State private var endSecString: String = "00"
    
    @State private var tempoPercentage: Double = 0.0
    @State private var localArtwork: NSImage? = nil
    /// Only a deliberate pick counts as custom art — art merely loaded from the file's tags
    /// shouldn't get duplicated into every saved project.
    @State private var didChooseArtwork: Bool = false
    @State private var isEditingTempoText: Bool = false
    @State private var tempoTextInput: String = ""
    @State private var customTempoOverride: Double? = nil
    @State private var editingTrackID: UUID? = nil
    @State private var tempoKeyMonitor: Any? = nil

    // Manual base BPM + the derived, slider-driven "current" BPM readout/edit
    @State private var manualBPMText: String = ""
    @State private var isEditingEffectiveBPMText: Bool = false
    @State private var effectiveBPMTextInput: String = ""

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
    
    
    private var isEditingSpotifyTrack: Bool {
        player.selectedTrackForEditing?.source == .spotify
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Bar
            // Header Bar inside MetadataEditorPanel
            HStack {
                Text("Metadata Editor")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        
                        withAnimation(.easeInOut(duration: 0.2)) {
                            player.selectedTrackForEditing = nil
                        }
                    }
            }
            .padding(.bottom, 4)
            
            // Artwork Well
            VStack(alignment: .center) {
                Group {
                    if let art = localArtwork {
                        Image(nsImage: art)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(hex: "#18181b")
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 32))
                                .foregroundColor(.gray)
                        }
                    }
                }
                .frame(width: 110, height: 110)
                .cornerRadius(8)
                .clipped()
                .onTapGesture {
                    importCoverArtImage()
                }
            }
            
            
            .frame(maxWidth: .infinity)
            .padding(.top, 10)
            
            Text("Click the image above to change the cover art")
                .gridColumnAlignment(.center)
                .font(.system(size: 8))
                .foregroundColor(.gray)
            
            Divider()
                .background(Color(hex: "#27272a"))
                .padding(.vertical, 4)
            
            // Meta Fields
            VStack(alignment: .leading, spacing: 4) {
                Text("SONG TITLE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                TextField("Title", text: $editableTitle)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("ARTIST NAME")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                TextField("Artist", text: $editableArtist)
                    .textFieldStyle(.roundedBorder)
            }
            
            Divider()
                .background(Color(hex: "#27272a"))
                .padding(.vertical, 4)
            
            // Typed timestamps are the only way to trim a Spotify track. A local file gets the
            // waveform instead, where the same two numbers can be seen against the audio.
            if isEditingSpotifyTrack {
                timestampField(
                    title: "START TIMESTAMP",
                    minutes: $startMinString,
                    seconds: $startSecString,
                    edge: .start
                )

                timestampField(
                    title: "END TIMESTAMP",
                    minutes: $endMinString,
                    seconds: $endSecString,
                    edge: .end
                )
            } else {
                openTimingEditorButton
            }

            if !isEditingSpotifyTrack {
                // Engine Modification Constraints: Tempo Warp
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
                                .onSubmit {
                                    commitTempoTextInput()
                                }
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

                        if baseBPMValue != nil {
                            Text("→")
                                .font(.system(size: 11))
                                .foregroundColor(.gray)

                            if isEditingEffectiveBPMText {
                                TextField("bpm", text: $effectiveBPMTextInput)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 55)
                                    .font(.system(size: 11, weight: .bold))
                                    .onSubmit {
                                        commitEffectiveBPMTextInput()
                                    }
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
                            customTempoOverride = nil
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
            } else {
                Text("Detailed Editing is Not Available for Spotify Tracks")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color(hex: "#111114"))
        .onAppear {
            hydrateFormFields()
            installTempoKeyMonitor()
        }
        .onChange(of: player.selectedTrackForEditing) { oldValue, newValue in
            hydrateFormFields()
        }
        .onDisappear {
            removeTempoKeyMonitor()
            saveMetadataModifications()
        }
    }
    
    /// Stands aside when a text field or the waveform sheet needs the arrow keys for its own purpose.
    private func installTempoKeyMonitor() {
        removeTempoKeyMonitor()
        tempoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard player.selectedTrackForEditing != nil,
                  player.timingEditorTrackID == nil,
                  !isEditingSpotifyTrack
            else { return event }

            // Arrow keys always carry `.function`/`.numericPad`, so only refuse modifiers that would mean something else.
            let modifiers = event.modifierFlags
            guard !modifiers.contains(.command),
                  !modifiers.contains(.option),
                  !modifiers.contains(.control)
            else { return event }
            if NSApp.keyWindow?.firstResponder is NSTextView { return event }

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
        customTempoOverride = updated
        HapticFeedback.perform(.levelChange)
    }

    /// Opening the waveform is also a commit: the timing editor reads the stored track, so
    /// anything still sitting in this panel's fields would be silently reverted by it otherwise.
    private var openTimingEditorButton: some View {
        Button {
            saveMetadataModifications()
            if let editingTrackID {
                player.openTimingEditor(for: editingTrackID)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Text("Edit Length")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(hex: "#71717a"))
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
        .help("Set the start and end points against the waveform, and fade in or out")
    }

    /// Minutes and seconds, with a five second audition of that edge beside them. A Spotify
    /// track can't be drawn, so hearing it is the only way to tell whether the number is right.
    private func timestampField(
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
                Text(":")
                    .font(.system(size: 12, weight: .bold))
                TextField("Sec", text: seconds)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)

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

    /// Sent the values currently in the fields rather than the saved ones, so a timestamp can
    /// be checked before committing to it.
    private func previewSpotifyEdge(_ edge: SpotifyPreviewEdge) {
        guard let track = player.tracks.first(where: { $0.id == editingTrackID }) else { return }

        let start = (Double(startMinString) ?? 0) * 60 + (Double(startSecString) ?? 0)
        let end = (Double(endMinString) ?? 0) * 60 + (Double(endSecString) ?? 0)

        player.previewSpotifyEdge(
            edge,
            of: track,
            start: max(0, start),
            end: end > start ? end : track.duration
        )
    }

    private func commitTempoTextInput() {
        if let parsed = Double(tempoTextInput) {
            let clamped = max(-25, min(25, parsed))
            customTempoOverride = clamped
            tempoPercentage = clamped
        }
        isEditingTempoText = false
        tempoTextInput = ""
        HapticFeedback.perform(.levelChange)
    }

    private func commitEffectiveBPMTextInput() {
        if let base = baseBPMValue, let target = Double(effectiveBPMTextInput), base > 0 {
            let impliedPercentage = ((target / base) - 1) * 100
            let clamped = max(-25, min(25, impliedPercentage))
            customTempoOverride = clamped
            tempoPercentage = clamped
        }
        isEditingEffectiveBPMText = false
        effectiveBPMTextInput = ""
        HapticFeedback.perform(.levelChange)
    }

    private func hydrateFormFields() {
        guard let target = player.selectedTrackForEditing else { return }
        editingTrackID = target.id
        editableTitle = target.title
        editableArtist = target.artist
        localArtwork = target.artwork
        tempoPercentage = target.tempoPercentage
        manualBPMText = target.manualBPM
        
        let startTotalSec = Int(target.startTime)
        let startMin = startTotalSec / 60
        let startSec = startTotalSec % 60
        startMinString = String(startMin)
        startSecString = String(format: "%02d", startSec)
        
        let endTotalSec = Int(target.endTime ?? target.duration)
        let endMin = endTotalSec / 60
        let endSec = endTotalSec % 60
        endMinString = String(endMin)
        endSecString = String(format: "%02d", endSec)

        // Reading a song's audio is the slow part of opening the waveform, so it starts as
        // soon as the DJ is looking at the song rather than when they ask for the editor.
        if target.source == .local {
            WaveformCache.shared.prewarm(url: target.url)
        }
    }
    
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
                    }
                }
            }
        }
    }
    
    func saveMetadataModifications() {
        guard let editingTrackID,
              let matchIdx = player.tracks.firstIndex(where: { $0.id == editingTrackID }) else { return }
        
        let startMin = Double(startMinString) ?? 0.0
        let startSec = Double(startSecString) ?? 0.0
        let calculatedStart = max(0, (startMin * 60.0) + startSec)
        
        let endMin = Double(endMinString) ?? 0.0
        let endSec = Double(endSecString) ?? 0.0
        let calculatedEnd = (endMin * 60.0) + endSec

        let previousTempo = player.tracks[matchIdx].tempoPercentage

        var updatedTrack = player.tracks[matchIdx]
        updatedTrack.title = editableTitle
        updatedTrack.artist = editableArtist
        updatedTrack.artwork = localArtwork
        if didChooseArtwork { updatedTrack.hasCustomArtwork = true }
        if updatedTrack.source == .local {
            updatedTrack.tempoPercentage = tempoPercentage
        }
        updatedTrack.manualBPM = manualBPMText
        // Only Spotify tracks are trimmed from this panel now; writing these back for a local
        // file would undo whatever the waveform editor had just set.
        if updatedTrack.source == .spotify {
            updatedTrack.startTime = calculatedStart
            updatedTrack.endTime = (calculatedEnd < updatedTrack.duration && calculatedEnd > calculatedStart) ? calculatedEnd : nil
        }

        // Opening and closing without an edit shouldn't push a do-nothing undo entry that clobbers the redo stack.
        guard updatedTrack != player.tracks[matchIdx] else { return }

        player.recordUndoSnapshot("Edit Song Details")
        player.tracks[matchIdx] = updatedTrack
        
        if player.currentIndex == matchIdx {
            player.synchronizeActiveTrackSettings()
        }
        
        // Auto-commit properties directly to the permanent library JSON cache
        player.saveTrack(updatedTrack)

        // Time-stretching overshoots peaks, so the gain has to be re-derived against the
        // stretched audio or a boost sized for the original will clip.
        if updatedTrack.tempoPercentage != previousTempo {
            player.relevelGainForTempoChange(trackID: updatedTrack.id)
        }
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

    /// Files the typed text under "Other" (so `formattedStylesDisplay` shows it as-is)
    /// when nothing predefined matches what the DJ typed.
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

                    // Shown whenever the cued dance has an intro, autoplay or not: announcing
                    // one is a decision the DJ makes, not something a countdown implies.
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

    /// Renders at this size when it fits; `minimumScaleFactor` takes it down for a long
    /// title rather than scrolling, which would make the DJ wait to read the end.
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
            // Sized to the next-song line it stands in for, since it's now the only thing on
            // that row rather than a note beside it.
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
            // One concatenated Text, not an HStack, so the scale-to-fit applies evenly
            // across the whole line instead of shrinking each run on its own.
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

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { player.previous() }) {
                Image(systemName: "backward.end.fill")
                    .foregroundColor(.white)
            }.buttonStyle(TransportButtonStyle())
            .pointingHandCursor()

            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isBetweenSongs ? "play.circle.fill" : (player.isPlaying ? "pause.fill" : "play.fill"))
            }.buttonStyle(TransportButtonStyle(primary: true))
            .pointingHandCursor()

            Button(action: { player.next() }) {
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
    /// When false, never scrolls (renders static truncated text) — used to pause the
    /// continuous per-frame animation while a heavier task (e.g. importing) is running.
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

            Button("Detect BPM for All Songs (⌘B)") { player.detectBPMForLibrary() }
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
