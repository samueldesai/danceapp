//
//  MainControlView.swift
//  Dance Player
//
//  Created by Samuel Desai on 6/15/26.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - WINDOW 1: Main Control View
struct ContentView: View {
    @StateObject private var player = PlayerController()

    var body: some View {
        ZStack {
            HSplitView {
                PlaylistView(player: player)
                    .frame(minWidth: 240, maxWidth: 320)
                LibraryTableView(player: player)
            }
            
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
        }
        .background(Color(hex: "#0e0e10"))
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: player.selectedTrackForEditing)
    }
}

// MARK: - PLAYLIST QUEUE (FIXED DRAG & DROP ENGINE)
struct PlaylistView: View {
    @ObservedObject var player: PlayerController
    @State private var draggedTrack: Track? = nil
    
    // States allocated to manage the native macOS picker panels
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var activeExportDocument: JSONLibraryDocument? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            
            // MARK: - Header Toolbar (Cleaned up)
            HStack {
                Text("LIVE PLAYLIST QUEUE")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                    .tracking(0.5)
                
                Spacer()
                
                // ADD TRACK BUTTON (Kept here for library management convenience)
                Button(action: { player.openFilePicker() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

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
                        ForEach(Array(player.tracks.enumerated()), id: \.element.id) { index, track in
                            PlaylistRow(index: index + 1, track: track, isPlaying: player.currentIndex == index)
                                .onTapGesture(count: 2) {
                                    player.play(index: index)
                                }
                                .contextMenu {
                                    Button("Delete Track") { player.removeTrack(at: index) }
                                }
                                .onDrag {
                                    self.draggedTrack = track
                                    return NSItemProvider(object: track.id.uuidString as NSString)
                                }
                                .onDrop(of: [.text], delegate: PlaylistDropDelegate(
                                    targetTrack: track,
                                    player: player,
                                    draggedTrack: $draggedTrack
                                ))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
            
            // MARK: - Bottom Action Toolbar (New)
            VStack(spacing: 0) {
                Divider()
                    .background(Color(hex: "#1b1b1f"))
                
                HStack(spacing: 12) {
                    // IMPORT SET TEXT BUTTON
                    Button(action: {
                        self.isShowingImporter = true
                    }) {
                        Text("Import Metadata")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "#a3a3ac"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(hex: "#18181b"))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    
                    // EXPORT SET TEXT BUTTON
                    Button(action: {
                        if let rawData = player.generateLiveLibraryJSONData() {
                            self.activeExportDocument = JSONLibraryDocument(data: rawData)
                            self.isShowingExporter = true
                        }
                    }) {
                        Text("Export Metadata")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "#a3a3ac"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color(hex: "#18181b"))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(hex: "#0c0c0e"))
            }
        }
        .background(Color(hex: "#09090b"))
        // NATIVE MAC LOCATIONS PICKER EXPORTER
        .fileExporter(
            isPresented: $isShowingExporter,
            document: activeExportDocument,
            contentType: .json,
            defaultFilename: "dance_player_library_export"
        ) { result in
            if case .success(let savedURL) = result {
                print("JSON File successfully committed via user picker target: \(savedURL.path)")
            }
        }
        // NATIVE MAC FILE IMPORTER LOCATION PICKER
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                let accessSecure = selectedURL.startAccessingSecurityScopedResource()
                if let rawData = try? Data(contentsOf: selectedURL) {
                    player.importAndMergeLibraryChanges(from: rawData)
                }
                if accessSecure {
                    selectedURL.stopAccessingSecurityScopedResource()
                }
            case .failure(let error):
                print("File selection error: \(error.localizedDescription)")
            }
        }
    }
}

struct PlaylistRow: View {
    let index: Int
    let track: Track
    let isPlaying: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if isPlaying {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#3478f6"))
                    .frame(width: 16)
            } else {
                Text("\(index).")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#44444a"))
                    .frame(width: 16, alignment: .leading)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 11, weight: isPlaying ? .bold : .medium))
                    .foregroundColor(isPlaying ? .white : Color(hex: "#a3a3ac"))
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundColor(Color(hex: "#6b6b75"))
                    .lineLimit(1)
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
        .background(isPlaying ? Color(hex: "#142844") : Color(hex: "#131316"))
        .cornerRadius(5)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isHovering ? Color.gray.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in isHovering = hovering }
    }
}

// MARK: - DRAG AND DROP UTILITY ENVIRONMENT
struct PlaylistDropDelegate: DropDelegate {
    let targetTrack: Track
    let player: PlayerController
    @Binding var draggedTrack: Track?

    func performDrop(info: DropInfo) -> Bool {
        self.draggedTrack = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedTrack,
              dragged != targetTrack,
              let fromIndex = player.tracks.firstIndex(where: { $0.id == dragged.id }),
              let toIndex = player.tracks.firstIndex(where: { $0.id == targetTrack.id })
        else { return }

        // Core array modification handling matching your layout changes
        withAnimation(.linear(duration: 0.15)) {
            player.objectWillChange.send()
            
            let oldCurrentIndex = player.currentIndex
            var currentTrackRef: Track? = nil
            if let idx = oldCurrentIndex, player.tracks.indices.contains(idx) {
                currentTrackRef = player.tracks[idx]
            }
            
            player.tracks.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            
            if let ref = currentTrackRef {
                player.currentIndex = player.tracks.firstIndex(where: { $0.id == ref.id })
            }
        }
    }
}

struct LibraryTableView: View {
    @ObservedObject var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                TransportControls(player: player)
                
                Spacer()
                
                Button(action: { player.openDisplayWindow() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "macwindow")
                        Text("Open Audience Screen")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(hex: "#111114"))

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
                Rectangle().fill(Color(hex: "#1c1c22")).frame(height: 1)

                ScrollView {
                    VStack(spacing: 0) {
                        if player.tracks.isEmpty {
                            Text("No tracks loaded in.")
                                .font(.system(size: 20))
                                .foregroundColor(Color(hex: "#a3a3ac"))
                                .padding(.top, 40)
                                .padding(.leading, 40)
                        } else {
                            ForEach(Array(player.tracks.enumerated()), id: \.element.id) { index, track in
                                TrackRow(player: player, track: track, index: index, isPlaying: player.currentIndex == index)
                                Rectangle()
                                        .fill(Color(hex: "#71717a"))
                                        .frame(height: 1)
                            }
                        }
                    }
                }
            }
            
            PlaybackStatusBar(player: player)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(hex: "#111114"))
        }
        .background(Color(hex: "#111114"))
    }
}

struct TrackRow: View {
    @ObservedObject var player: PlayerController
    let track: Track
    let index: Int
    let isPlaying: Bool
    @State private var isShowingPicker = false

    var body: some View {
        GridRow {
            // Column 1: Core Track Titles & Timings
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
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
                
                Spacer(minLength: 16)
                    
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
            .frame(maxWidth: .infinity)
            .popover(isPresented: $isShowingPicker, arrowEdge: .trailing) {
                DanceStyleMultiSelectorPopover(player: player, trackIndex: index)
            }

            // Column 3: Edit Metadata (Styled like Calculate ReplayGain & Formatted Left)
            HStack {
                Button(action: {
                    player.selectedTrackForEditing = track
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3") // Clean, standard icon for metadata/settings settings
                        Text("Edit Metadata")
                    }
                }
                .buttonStyle(DisplayWindowButtonStyle()) // Applies the exact style of the calculation button
                
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 15))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isPlaying ? Color(hex: "#142844") : Color.clear)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onTapGesture(count: 2) {
            player.play(index: index)
        }
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
                .onTapGesture { importCoverArtImage() }
            }
            .frame(maxWidth: .infinity)
            
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
            
            // Start Time Format Section (Minutes & Seconds)
            VStack(alignment: .leading, spacing: 4) {
                Text("START TIMESTAMP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 6) {
                    TextField("Min", text: $startMinString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text(":")
                        .font(.system(size: 12, weight: .bold))
                    TextField("Sec", text: $startSecString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }
            
            // End Time Format Section (Minutes & Seconds)
            VStack(alignment: .leading, spacing: 4) {
                Text("END TIMESTAMP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                
                HStack(spacing: 6) {
                    TextField("Min", text: $endMinString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text(":")
                        .font(.system(size: 12, weight: .bold))
                    TextField("Sec", text: $endSecString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
            }
            
            // Engine Modification Constraints: Tempo Warp
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("TEMPO ADJUSTMENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "%+.1f%%", tempoPercentage))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tempoPercentage == 0 ? .gray : .blue)
                }
                
                Slider(value: $tempoPercentage, in: -25...25, step: 0.5)
                    .accentColor(.blue)
                
                HStack {
                    Text("Slower")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                    Spacer()
                    Button("Reset Tempo") { tempoPercentage = 0.0 }
                        .font(.system(size: 9))
                        .buttonStyle(.plain)
                    Spacer()
                    Text("Faster")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
            }
            
            Spacer()
        }
        .padding(16)
        .background(Color(hex: "#111114"))
        .onAppear {
            hydrateFormFields()
        }
        .onChange(of: player.selectedTrackForEditing) { oldValue, newValue in
            hydrateFormFields()
        }
        .onDisappear {
            saveMetadataModifications()
        }
    }
    
    private func hydrateFormFields() {
        guard let target = player.selectedTrackForEditing else { return }
        editableTitle = target.title
        editableArtist = target.artist
        localArtwork = target.artwork
        tempoPercentage = target.tempoPercentage
        
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
                    }
                }
            }
        }
    }
    
    // Core structural calculations remain perfect, but don't clear player state context anymore since onDisappear handles it
    func saveMetadataModifications() {
        // Look for the last track edited inside player data cache safely if index reference dropped early
        guard let target = player.selectedTrackForEditing ?? player.tracks.first(where: { $0.title == editableTitle || $0.artist == editableArtist }),
              let matchIdx = player.tracks.firstIndex(where: { $0.id == target.id }) else { return }
        
        let startMin = Double(startMinString) ?? 0.0
        let startSec = Double(startSecString) ?? 0.0
        let calculatedStart = max(0, (startMin * 60.0) + startSec)
        
        let endMin = Double(endMinString) ?? 0.0
        let endSec = Double(endSecString) ?? 0.0
        let calculatedEnd = (endMin * 60.0) + endSec
        
        player.tracks[matchIdx].title = editableTitle
        player.tracks[matchIdx].artist = editableArtist
        player.tracks[matchIdx].artwork = localArtwork
        player.tracks[matchIdx].startTime = calculatedStart
        
        if calculatedEnd < player.tracks[matchIdx].duration && calculatedEnd > calculatedStart {
            player.tracks[matchIdx].endTime = calculatedEnd
        } else {
            player.tracks[matchIdx].endTime = nil
        }
        player.tracks[matchIdx].tempoPercentage = tempoPercentage
        
        if player.currentIndex == matchIdx {
            player.synchronizeActiveTrackSettings()
        }
        
        // Auto-commit properties directly to the permanent library JSON cache
        player.saveTrack(player.tracks[matchIdx])
    }
}

struct DanceStyleMultiSelectorPopover: View {
    @ObservedObject var player: PlayerController
    let trackIndex: Int
    @State private var searchText: String = ""
    
    private var filteredStyles: [String] {
        if searchText.isEmpty {
            return predefinedDanceStyles
        } else {
            return predefinedDanceStyles.filter { style in
                style.localizedCaseInsensitiveContains(searchText)
            }
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
                        Text("No styles match your filter")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                            .padding(.top, 20)
                            .padding(.leading, 40)
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
                    TextField("Type custom style...", text: Binding(
                        get: { player.tracks.indices.contains(trackIndex) ? player.tracks[trackIndex].customStyle : "" },
                        set: { newValue in
                            if player.tracks.indices.contains(trackIndex) {
                                player.tracks[trackIndex].customStyle = newValue
                            }
                        }
                    ))
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
        guard player.tracks.indices.contains(trackIndex) else { return false }
        return player.tracks[trackIndex].danceStyles.contains(style)
    }
    
    private func toggleStyleSelection(_ style: String) {
        guard player.tracks.indices.contains(trackIndex) else { return }
        if player.tracks[trackIndex].danceStyles.contains(style) {
            player.tracks[trackIndex].danceStyles.remove(style)
        } else {
            player.tracks[trackIndex].danceStyles.insert(style)
        }
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
                .help("Click to change active artwork image raw payload.")
                .onTapGesture {
                    player.importArtworkForCurrentTrack()
                }

                VStack(alignment: .leading, spacing: 2) {
                    if let last = player.lastTrack {
                        Text("LAST PLAYED: \(last.title) — \(last.artist) - \(last.formattedStylesDisplay)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Color(hex: "#5b34f6"))
                    }
                    HStack(spacing: 6) {
                        if player.isBetweenSongs {
                            Text("The Next Song Is A")
                                .font(.system(size: 25, weight: .bold))
                                .foregroundColor(Color(hex: "#eab308"))
                        }
                        Text(player.currentTrack?.formattedStylesDisplay ?? "Nothing playing")
                            .font(.system(size: 25, weight: .medium))
                            .foregroundColor(player.isBetweenSongs ? Color(hex: "#eab308") : Color(hex: "#3478f6"))
                    }
                }
                Spacer()
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#4e4e54"))
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
                    player.seek(to: player.currentTime)
                }
            })
            .accentColor(player.isBetweenSongs ? Color(hex: "#eab308") : Color(hex: "#3478f6"))
            .labelsHidden()
        }
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

            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isBetweenSongs ? "play.circle.fill" : (player.isPlaying ? "pause.fill" : "play.fill"))
            }.buttonStyle(TransportButtonStyle(primary: true))

            Button(action: { player.next() }) {
                Image(systemName: "forward.end.fill")
                    .foregroundColor(.white)
            }.buttonStyle(TransportButtonStyle())
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

struct TransportButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: primary ? 15 : 13))
            .foregroundColor(primary ? .white : Color(hex: "#52525b"))
            .frame(width: primary ? 28 : 22, height: 22)
            .background(primary ? Color(hex: "#27272a") : Color.clear)
            .cornerRadius(4)
    }
}

struct JSONLibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    
    var dataPayload: Data

    init(data: Data) {
        self.dataPayload = data
    }

    init(configuration: ReadConfiguration) throws {
        self.dataPayload = Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: dataPayload)
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
    }
}
