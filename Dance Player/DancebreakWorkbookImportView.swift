//
//  DancebreakWorkbookImportView.swift
//  Dance Player
//
//  Bulk import from a "Dancebreak DJ Workbook" spreadsheet (CSV or XLSX).
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Row Model

struct WorkbookImportRow: Identifiable {
    let id = UUID()
    var order: Int?
    var title: String
    var artist: String
    var bpm: String
    var lengthText: String
    var rawStyle: String
    var isLocal: Bool
    var resolvedStyles: Set<String>
    var customStyleText: String
    var matchedPopularEdit: PopularEdit?

    // Populated by the "Find Spotify Matches" step — auto-fetched, but still needs an
    // explicit DJ approval before Confirm will actually import it.
    var spotifyMatch: Track? = nil
    var spotifySearchAttempted: Bool = false
    var isSpotifyApproved: Bool = false

    // Set once this row is actually imported — lets Confirm be clicked again (after
    // fixing a skipped row) without re-running already-succeeded rows, which would
    // otherwise re-prompt the file picker for every local song all over again.
    var hasBeenImported: Bool = false
}

// MARK: - Style resolution

/// The workbook's Style column is a fixed spreadsheet dropdown (see the reference list the
/// DJ shared), so there's no typo variance to guard against — only these four dropdown
/// labels differ from the app's canonical style name; everything else either matches a
/// predefined style exactly already, or is an umbrella category that falls through to
/// "Other" (handled by `genericStylePlaceholders` below).
private let workbookStyleAliases: [String: String] = [
    "rotary": "Rotary Waltz",
    "cross-step": "Cross-Step Waltz",
    "wcs": "West Coast Swing",
    "nc2s": "Night Club Two Step"
]

/// Style tags that are umbrella categories rather than a specific dance/choreography name —
/// the CSV dropdown only ever offers the category, so there's nothing more specific to
/// carry over automatically. Left blank (instead of echoing the category label) so the DJ
/// can type the actual name in during review.
private let genericStylePlaceholders: Set<String> = ["line dance", "choreography", "mixer"]

/// Splits a raw workbook "Style" cell (comma-separated tags, chosen from a fixed dropdown
/// so there's no typo variance to account for) into canonical predefined styles plus any
/// leftover text that doesn't match anything, filed under "Other".
func resolveWorkbookStyles(from rawStyle: String) -> (styles: Set<String>, customText: String) {
    var tokens = rawStyle
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    var styles = Set<String>()

    // "Cross-Step" + "Mixer" chosen together means the specific "Cross-Step Waltz Mixer",
    // not the generic Mixer category.
    let lowerTokens = tokens.map { $0.lowercased() }
    let hasCrossStep = lowerTokens.contains("cross-step") || lowerTokens.contains("cross step")
    let hasMixer = lowerTokens.contains("mixer")
    if hasCrossStep, hasMixer {
        styles.insert("Cross-Step Waltz Mixer")
        tokens.removeAll { ["cross-step", "cross step", "mixer"].contains($0.lowercased()) }
    }

    var leftovers: [String] = []
    for token in tokens {
        let lower = token.lowercased()
        if let canonical = workbookStyleAliases[lower] {
            styles.insert(canonical)
        } else if let exact = predefinedDanceStyles.first(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) {
            styles.insert(exact)
        } else {
            leftovers.append(token)
        }
    }

    if !leftovers.isEmpty {
        styles.insert("Other")
    }

    let customText: String
    if leftovers.count == 1, genericStylePlaceholders.contains(leftovers[0].lowercased()) {
        customText = ""
    } else {
        customText = leftovers.joined(separator: ", ")
    }

    return (styles, customText)
}

/// Checks a row's title/artist/style text against the app's bundled "Popular Edits" so
/// well-known tracks (Barbie Line Dance, Bohemian National Polka, Romany Polka, etc.)
/// automatically use the shipped local audio file instead of asking the DJ to pick one.
func matchedPopularEdit(title: String, artist: String, rawStyle: String) -> PopularEdit? {
    let haystack = "\(title) \(artist) \(rawStyle)".lowercased()

    if haystack.contains("dance the night") && haystack.contains("dua lipa") {
        return PopularEdit.allCases.first { $0.id == "barbie-line-dance" }
    }

    for edit in PopularEdit.allCases {
        if haystack.contains(edit.displayName.lowercased()) {
            return edit
        }
    }

    if haystack.contains("bnp") {
        return PopularEdit.allCases.first { $0.id == "bohemian-national-polka" }
    }

    return nil
}

// MARK: - Column mapping

private struct WorkbookColumnMap {
    var order: Int?
    var title: Int?
    var artist: Int?
    var edited: Int?
    var bpm: Int?
    var length: Int?
    var style: Int?
}

/// Fuzzy header matching so extra/renamed columns in the workbook don't break parsing —
/// only the first column whose header contains the relevant keyword is used.
private func mapColumns(header: [String]) -> WorkbookColumnMap {
    var map = WorkbookColumnMap()
    for (index, rawHeader) in header.enumerated() {
        let h = rawHeader.lowercased()
        if map.order == nil, h.contains("order") { map.order = index }
        if map.title == nil, h.contains("title") { map.title = index }
        if map.artist == nil, (h.contains("artist") || h.contains("composer")) { map.artist = index }
        if map.edited == nil, h.contains("edited") { map.edited = index }
        if map.bpm == nil, h.contains("bpm") { map.bpm = index }
        if map.length == nil, h.contains("length") { map.length = index }
        if map.style == nil, h.contains("style") { map.style = index }
    }
    return map
}

// MARK: - CSV parsing

/// Hand-rolled CSV tokenizer — handles quoted fields, embedded commas/newlines, and
/// doubled-quote ("") escaping, since spreadsheet exports commonly contain all three.
func parseCSVRows(data: Data) -> [[String]] {
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
        return []
    }

    var rows: [[String]] = []
    var currentRow: [String] = []
    var currentField = ""
    var insideQuotes = false

    // Iterate Unicode scalars, not Characters — Swift's grapheme clustering merges a
    // "\r\n" pair into a single Character, which would silently defeat CRLF splitting.
    let scalars = Array(text.unicodeScalars)
    var i = 0
    while i < scalars.count {
        let c = scalars[i]

        if insideQuotes {
            if c == "\"" {
                if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                    currentField.unicodeScalars.append("\"")
                    i += 1
                } else {
                    insideQuotes = false
                }
            } else {
                currentField.unicodeScalars.append(c)
            }
        } else {
            switch c {
            case "\"":
                insideQuotes = true
            case ",":
                currentRow.append(currentField)
                currentField = ""
            case "\r":
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                currentRow.append(currentField)
                currentField = ""
                rows.append(currentRow)
                currentRow = []
            case "\n":
                currentRow.append(currentField)
                currentField = ""
                rows.append(currentRow)
                currentRow = []
            default:
                currentField.unicodeScalars.append(c)
            }
        }
        i += 1
    }

    if !currentField.isEmpty || !currentRow.isEmpty {
        currentRow.append(currentField)
        rows.append(currentRow)
    }

    return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

// MARK: - XLSX parsing (best-effort: single sheet, shared strings, no rich formatting)

private func columnIndex(fromCellReference ref: String) -> Int {
    var index = 0
    for scalar in ref.unicodeScalars {
        guard scalar.value >= 65, scalar.value <= 90 else { break }
        index = index * 26 + Int(scalar.value - 64)
    }
    return max(0, index - 1)
}

private func unzipEntry(from fileURL: URL, entryName: String) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-p", fileURL.path, entryName]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0, !data.isEmpty else { return nil }
    return data
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentText = ""
    private var currentEntry = ""
    private var isInsideText = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "si" { currentEntry = "" }
        if elementName == "t" { isInsideText = true; currentText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideText { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" {
            currentEntry += currentText
            isInsideText = false
        }
        if elementName == "si" {
            strings.append(currentEntry)
        }
    }
}

private final class SheetRowsParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    var rows: [[String]] = []

    private var currentRowCells: [Int: String] = [:]
    private var maxColumnInRow = 0
    private var currentCellRef = ""
    private var currentCellType = ""
    private var currentValue = ""
    private var isInsideValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        switch elementName {
        case "row":
            currentRowCells = [:]
            maxColumnInRow = 0
        case "c":
            currentCellRef = attributeDict["r"] ?? ""
            currentCellType = attributeDict["t"] ?? ""
            currentValue = ""
        case "v", "t":
            isInsideValue = true
            currentValue = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isInsideValue { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t":
            isInsideValue = false
        case "c":
            let colIndex = columnIndex(fromCellReference: currentCellRef)
            var resolved = currentValue
            if currentCellType == "s", let sharedIndex = Int(currentValue), sharedStrings.indices.contains(sharedIndex) {
                resolved = sharedStrings[sharedIndex]
            }
            currentRowCells[colIndex] = resolved
            maxColumnInRow = max(maxColumnInRow, colIndex)
        case "row":
            var rowArray = [String](repeating: "", count: maxColumnInRow + 1)
            for (index, value) in currentRowCells { rowArray[index] = value }
            rows.append(rowArray)
        default:
            break
        }
    }
}

/// Best-effort XLSX reader: unzips the first worksheet + shared strings table and walks
/// the raw XML. Handles plain single-sheet spreadsheets (text/number cells); doesn't
/// handle multiple sheets, merged cells, or special date/number formatting.
func parseXLSXRows(fileURL: URL) -> [[String]] {
    var sharedStrings: [String] = []
    if let sharedStringsData = unzipEntry(from: fileURL, entryName: "xl/sharedStrings.xml") {
        let parser = XMLParser(data: sharedStringsData)
        let delegate = SharedStringsParser()
        parser.delegate = delegate
        parser.parse()
        sharedStrings = delegate.strings
    }

    guard let sheetData = unzipEntry(from: fileURL, entryName: "xl/worksheets/sheet1.xml") else {
        return []
    }

    let parser = XMLParser(data: sheetData)
    let delegate = SheetRowsParser(sharedStrings: sharedStrings)
    parser.delegate = delegate
    parser.parse()
    return delegate.rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

// MARK: - Row assembly

private func parseWorkbookRows(from rawRows: [[String]]) -> [WorkbookImportRow] {
    guard let header = rawRows.first else { return [] }
    let map = mapColumns(header: header)

    func field(_ row: [String], _ index: Int?) -> String {
        guard let index, index < row.count else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var results: [WorkbookImportRow] = []

    for row in rawRows.dropFirst() {
        let title = field(row, map.title)
        guard !title.isEmpty else { continue }

        let artistField = field(row, map.artist)
        let artist = artistField.isEmpty ? "Unknown Artist" : artistField
        let editedRaw = field(row, map.edited).lowercased()
        let isEditedTrue = editedRaw == "true" || editedRaw == "1" || editedRaw == "yes"
        let rawStyle = field(row, map.style)

        let (styles, customText) = resolveWorkbookStyles(from: rawStyle)
        let popularEdit = matchedPopularEdit(title: title, artist: artist, rawStyle: rawStyle)

        results.append(
            WorkbookImportRow(
                order: Int(field(row, map.order)),
                title: title,
                artist: artist,
                bpm: field(row, map.bpm),
                lengthText: field(row, map.length),
                rawStyle: rawStyle,
                isLocal: popularEdit != nil ? true : isEditedTrue,
                resolvedStyles: popularEdit?.danceStyles ?? styles,
                customStyleText: popularEdit != nil ? "" : customText,
                matchedPopularEdit: popularEdit
            )
        )
    }

    return results.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
}

/// Entry point: detects CSV vs XLSX by extension and returns the parsed, order-sorted rows.
func loadWorkbookRows(from url: URL) -> [WorkbookImportRow] {
    let rawRows: [[String]]
    if url.pathExtension.lowercased() == "xlsx" {
        rawRows = parseXLSXRows(fileURL: url)
    } else {
        guard let data = try? Data(contentsOf: url) else { return [] }
        rawRows = parseCSVRows(data: data)
    }
    return parseWorkbookRows(from: rawRows)
}

// MARK: - Review View

private let workbookOrderColumnWidth: CGFloat = 28
private let workbookSongColumnWidth: CGFloat = 240
private let workbookSourceColumnWidth: CGFloat = 150
private let workbookStylesColumnWidth: CGFloat = 220
private let workbookBPMColumnWidth: CGFloat = 60


/// Solid blue, bold white text — used for the primary actions in this flow (Confirm,
/// Find Spotify Matches, Approve) so they read clearly against the dark background.
private struct WorkbookPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(hex: "#3478f6"))
            .cornerRadius(6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct WorkbookImportReviewView: View {
    @ObservedObject var player: PlayerController
    @State var rows: [WorkbookImportRow]
    var onFinished: () -> Void

    @State private var spotifyClientID: String = UserDefaults.standard.string(forKey: "spotifyClientID") ?? ""
    @State private var isImporting = false
    @State private var currentSongIndex = 0
    @State private var currentImportTotal = 0
    @State private var currentImportRowTitle = ""
    @State private var currentImportRowID: UUID? = nil
    @State private var failureSummary: [String] = []

    // "Find Spotify Matches" fetches everything up front (cover art shown inline per
    // row) instead of searching/picking one at a time during Confirm — the DJ approves
    // each match here, so Confirm just imports whatever's already been approved.
    @State private var isFetchingSpotifyMatches = false
    @State private var spotifyFetchCompletedCount = 0
    @State private var spotifyFetchTotalCount = 0

    // Confirm-time fallback for a row that reaches Confirm with no approved match —
    // rather than just skipping it, let the DJ search or paste a link right there.
    @State private var isPresentingSpotifyFallback = false
    @State private var spotifyFallbackRow: WorkbookImportRow? = nil
    @State private var spotifyFallbackQuery = ""
    @State private var spotifyFallbackResults: [Track] = []
    @State private var isSearchingSpotifyFallback = false
    @State private var spotifyFallbackContinuation: CheckedContinuation<Track?, Never>? = nil

    private var needsSpotify: Bool {
        rows.contains { !$0.isLocal && $0.matchedPopularEdit == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))

            if needsSpotify {
                spotifyClientIDBar
                Divider().background(Color(hex: "#242429"))
            }

            columnHeader
            Divider().background(Color(hex: "#242429"))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach($rows) { $row in
                        WorkbookRowEditor(row: $row, isActive: isImporting && row.id == currentImportRowID)
                        Divider().background(Color(hex: "#1c1c22"))
                    }
                }
            }
            .disabled(isImporting)

            if !failureSummary.isEmpty {
                Divider().background(Color(hex: "#242429"))
                failureBanner
            }

            Divider().background(Color(hex: "#242429"))
            footer
                .disabled(isImporting)
        }
        .background(Color(hex: "#0e0e10"))
        .overlay {
            if isImporting {
                importingOverlay
            }
        }
        .sheet(isPresented: $isPresentingSpotifyFallback) {
            spotifyFallbackSheet
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dancebreak DJ Workbook Import")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text("\(rows.count) song\(rows.count == 1 ? "" : "s") found — review sources and styles, then confirm.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#71717a"))

                HStack(spacing: 8) {
                    Text("Project Name")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#a3a3ac"))
                    TextField("Project Name", text: $player.projectName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 260)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(16)
    }

    private var spotifyClientIDBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Spotify Client ID")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                TextField("Required when Local File? is unchecked", text: $spotifyClientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button(action: fetchAllSpotifyMatches) {
                    Text(isFetchingSpotifyMatches ? "Finding Matches… \(spotifyFetchCompletedCount)/\(spotifyFetchTotalCount)" : "Find Spotify Matches")
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .disabled(isFetchingSpotifyMatches || spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Fetches cover art for every Spotify-marked row up front — review each match below and approve it before confirming. You'll be asked to approve access in your browser the first time.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: workbookOrderColumnWidth, alignment: .leading)
            Text("SONG").frame(width: workbookSongColumnWidth, alignment: .leading)
            Text("LOCAL FILE?").frame(width: workbookSourceColumnWidth, alignment: .leading)
            Text("STYLES").frame(width: workbookStylesColumnWidth, alignment: .leading)
            Text("BPM").frame(width: workbookBPMColumnWidth, alignment: .leading)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .bold))
        .foregroundColor(.white)
        .tracking(0.5)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Needs attention (\(failureSummary.count)):")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "#eab308"))
            ForEach(failureSummary, id: \.self) { message in
                Text("• \(message)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                onFinished()
            }
            .buttonStyle(DisplayWindowButtonStyle())

            Spacer()

            Button(action: startImport) {
                Text("Confirm — Import \(remainingImportCount) Song\(remainingImportCount == 1 ? "" : "s")")
            }
            .buttonStyle(WorkbookPrimaryButtonStyle())
            .disabled(remainingImportCount == 0)
        }
        .padding(16)
    }

    private var remainingImportCount: Int {
        rows.filter { !$0.hasBeenImported }.count
    }

    private var importingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 10) {
                ProgressView(value: Double(currentSongIndex), total: Double(max(1, currentImportTotal)))
                    .controlSize(.large)
                    .frame(width: 240)
                Text(currentSongIndex < currentImportTotal ? "Importing \"\(currentImportRowTitle)\"…" : "Finishing up…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Text("\(min(currentSongIndex, currentImportTotal)) of \(currentImportTotal)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#a3a3ac"))
            }
            .padding(24)
            .background(Color(hex: "#111114").opacity(0.96))
            .cornerRadius(12)
        }
    }

    /// Fetches a Spotify match for every row that still needs one (marked Spotify, no
    /// bundled Popular Edit match, and no match found yet) — safe to click again after
    /// fixing a title, since already-matched rows are left alone.
    private func fetchAllSpotifyMatches() {
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return }
        UserDefaults.standard.set(spotifyClientID, forKey: "spotifyClientID")

        let targetIndices = rows.indices.filter {
            !rows[$0].isLocal && rows[$0].matchedPopularEdit == nil && rows[$0].spotifyMatch == nil
        }
        guard !targetIndices.isEmpty else { return }

        isFetchingSpotifyMatches = true
        spotifyFetchTotalCount = targetIndices.count
        spotifyFetchCompletedCount = 0

        Task {
            for index in targetIndices {
                let title = rows[index].title
                let artist = rows[index].artist
                let results = await player.searchWorkbookSpotifyTracks(title: title, artist: artist, clientID: clientID)
                await MainActor.run {
                    rows[index].spotifyMatch = results.first
                    rows[index].spotifySearchAttempted = true
                    // Pre-approved by default — the DJ deselects it if the match is wrong.
                    rows[index].isSpotifyApproved = results.first != nil
                    spotifyFetchCompletedCount += 1
                }
            }
            await MainActor.run {
                isFetchingSpotifyMatches = false
            }
        }
    }

    private func startImport() {
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only rows that haven't already succeeded — re-clicking Confirm after fixing a
        // skipped row must not re-run rows that already imported fine (which would mean
        // re-prompting the file picker for every local song all over again).
        let indicesToImport = rows.indices.filter { !rows[$0].hasBeenImported }

        guard !indicesToImport.isEmpty else {
            onFinished()
            return
        }

        isImporting = true
        currentSongIndex = 0
        currentImportTotal = indicesToImport.count
        failureSummary = []

        Task {
            for (progress, index) in indicesToImport.enumerated() {
                let row = rows[index]
                await MainActor.run {
                    currentSongIndex = progress
                    currentImportRowTitle = row.title
                    currentImportRowID = row.id
                }

                if let edit = row.matchedPopularEdit {
                    await player.importWorkbookPopularEdit(
                        edit,
                        title: row.title,
                        artist: row.artist,
                        danceStyles: row.resolvedStyles,
                        customStyle: row.customStyleText,
                        manualBPM: row.bpm
                    )
                    await MainActor.run { rows[index].hasBeenImported = true }
                } else if row.isLocal {
                    if let url = await pickLocalFile(for: row) {
                        await player.importWorkbookLocalFile(
                            url: url,
                            title: row.title,
                            artist: row.artist,
                            danceStyles: row.resolvedStyles,
                            customStyle: row.customStyleText,
                            manualBPM: row.bpm
                        )
                        await MainActor.run { rows[index].hasBeenImported = true }
                    } else {
                        await MainActor.run {
                            failureSummary.append("\(row.title) — no file selected, skipped")
                        }
                    }
                } else if let match = row.spotifyMatch, row.isSpotifyApproved {
                    await player.importWorkbookSpotifyMatch(
                        match,
                        danceStyles: row.resolvedStyles,
                        customStyle: row.customStyleText,
                        manualBPM: row.bpm
                    )
                    await MainActor.run { rows[index].hasBeenImported = true }
                } else if clientID.isEmpty {
                    await MainActor.run {
                        failureSummary.append("\(row.title) — no Spotify Client ID entered, skipped")
                    }
                } else {
                    // No approved match by Confirm time — rather than just skipping it,
                    // let the DJ search or paste a link right here, one last chance.
                    if let chosen = await presentSpotifyFallback(for: row, clientID: clientID) {
                        await player.importWorkbookSpotifyMatch(
                            chosen,
                            danceStyles: row.resolvedStyles,
                            customStyle: row.customStyleText,
                            manualBPM: row.bpm
                        )
                        await MainActor.run { rows[index].hasBeenImported = true }
                    } else {
                        await MainActor.run {
                            failureSummary.append("\(row.title) — skipped by DJ")
                        }
                    }
                }
            }

            await MainActor.run {
                currentSongIndex = indicesToImport.count
                isImporting = false
                if failureSummary.isEmpty {
                    onFinished()
                }
            }
        }
    }

    private func pickLocalFile(for row: WorkbookImportRow) async -> URL? {
        await MainActor.run {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, UTType(filenameExtension: "flac")!, UTType(filenameExtension: "wav")!]
            panel.message = "Select the audio file for \"\(row.title)\" by \(row.artist)"
            panel.prompt = "Choose"
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    // MARK: - Confirm-time Spotify fallback

    private var spotifyFallbackSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Approved Spotify Match")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    if let row = spotifyFallbackRow {
                        Text("for \"\(row.title)\" — \(row.artist)")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#71717a"))
                    }
                }
                Spacer()
            }
            .padding(16)

            Divider().background(Color(hex: "#242429"))

            HStack(spacing: 8) {
                TextField("Search Spotify, or paste a track link", text: $spotifyFallbackQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { runSpotifyFallbackSearch() }
                Button("Search") { runSpotifyFallbackSearch() }
                    .buttonStyle(WorkbookPrimaryButtonStyle())
                    .disabled(isSearchingSpotifyFallback || spotifyFallbackQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)

            Divider().background(Color(hex: "#242429"))

            if isSearchingSpotifyFallback {
                VStack {
                    ProgressView()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if spotifyFallbackResults.isEmpty {
                VStack(spacing: 6) {
                    Text("No matches found")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gray)
                    Text("Try a different search above, or paste a Spotify track link.")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#52525b"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(spotifyFallbackResults) { track in
                            SpotifySearchResultRow(track: track) {
                                resolveSpotifyFallback(with: track)
                            }
                        }
                    }
                    .padding(12)
                }
            }

            Divider().background(Color(hex: "#242429"))

            HStack {
                Spacer()
                Button("Skip This Song") {
                    resolveSpotifyFallback(with: nil)
                }
                .buttonStyle(DisplayWindowButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 420, height: 520)
        .background(Color(hex: "#111114"))
        .preferredColorScheme(.dark)
    }

    private func isLikelySpotifyLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("spotify:")
    }

    private func runSpotifyFallbackSearch() {
        let trimmed = spotifyFallbackQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)

        isSearchingSpotifyFallback = true
        Task {
            if isLikelySpotifyLink(trimmed) {
                let track = await player.resolveWorkbookSpotifyURL(trimmed, clientID: clientID)
                await MainActor.run {
                    isSearchingSpotifyFallback = false
                    if let track {
                        resolveSpotifyFallback(with: track)
                    } else {
                        spotifyFallbackResults = []
                    }
                }
            } else {
                let results = await player.searchWorkbookSpotifyTracks(title: trimmed, artist: "", clientID: clientID)
                await MainActor.run {
                    isSearchingSpotifyFallback = false
                    spotifyFallbackResults = results
                }
            }
        }
    }

    private func resolveSpotifyFallback(with track: Track?) {
        spotifyFallbackContinuation?.resume(returning: track)
        spotifyFallbackContinuation = nil
        isPresentingSpotifyFallback = false
        spotifyFallbackRow = nil
        spotifyFallbackResults = []
        spotifyFallbackQuery = ""
    }

    private func presentSpotifyFallback(for row: WorkbookImportRow, clientID: String) async -> Track? {
        await MainActor.run {
            isPresentingSpotifyFallback = false
        }
        // Give SwiftUI a beat to fully dismiss any just-closed sheet before presenting
        // the next one — toggling isPresented true again too quickly can silently fail
        // to re-show it, which is exactly what made this look "stuck".
        try? await Task.sleep(for: .milliseconds(150))
        return await withCheckedContinuation { (continuation: CheckedContinuation<Track?, Never>) in
            spotifyFallbackRow = row
            spotifyFallbackQuery = "\(row.title) \(row.artist)"
            spotifyFallbackResults = row.spotifyMatch.map { [$0] } ?? []
            spotifyFallbackContinuation = continuation
            isPresentingSpotifyFallback = true
        }
    }
}

private struct WorkbookRowEditor: View {
    @Binding var row: WorkbookImportRow
    var isActive: Bool

    @State private var isShowingStylePicker = false

    private var needsSpotifyMatch: Bool {
        !row.isLocal && row.matchedPopularEdit == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if needsSpotifyMatch {
                spotifyMatchBar
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Color(hex: "#142844") : Color.clear)
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.order != nil ? "\(row.order!)" : "—")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#71717a"))
                .frame(width: workbookOrderColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                titleField
                artistField
            }
            .frame(width: workbookSongColumnWidth, alignment: .leading)

            Group {
                if let edit = row.matchedPopularEdit {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(Color(hex: "#22c55e"))
                        Text("Bundled: \(edit.displayName)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#22c55e"))
                    }
                } else {
                    Toggle(isOn: $row.isLocal) {
                        EmptyView()
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(width: workbookSourceColumnWidth, alignment: .leading)

            ZStack(alignment: .leading) {
                TextField(stylePlaceholder, text: .constant(displayStyleText()))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isShowingStylePicker = true }
            }
            .pointingHandCursor()
            .frame(width: workbookStylesColumnWidth, alignment: .leading)
            .popover(isPresented: $isShowingStylePicker, arrowEdge: .trailing) {
                DanceStyleMultiSelectorPopover(danceStyles: $row.resolvedStyles, customStyle: $row.customStyleText)
            }

            bpmField
                .frame(width: workbookBPMColumnWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var spotifyMatchBar: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: workbookOrderColumnWidth + 12)

            Group {
                if let match = row.spotifyMatch {
                    if let artwork = match.artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "music.note")
                            .foregroundColor(Color(hex: "#71717a"))
                    }
                } else if row.spotifySearchAttempted {
                    Image(systemName: "questionmark.circle")
                        .foregroundColor(Color(hex: "#eab308"))
                } else {
                    Image(systemName: "hourglass")
                        .foregroundColor(Color(hex: "#52525b"))
                }
            }
            .frame(width: 30, height: 30)
            .background(Color(hex: "#18181b"))
            .cornerRadius(4)

            if let match = row.spotifyMatch {
                VStack(alignment: .leading, spacing: 0) {
                    Text(match.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(match.artist)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#71717a"))
                        .lineLimit(1)
                }
                .frame(maxWidth: 260, alignment: .leading)

                Button(action: { row.isSpotifyApproved.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: row.isSpotifyApproved ? "checkmark.circle.fill" : "circle")
                        Text(row.isSpotifyApproved ? "Approved" : "Approve")
                    }
                    .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundColor(row.isSpotifyApproved ? .white : Color(hex: "#3478f6"))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(row.isSpotifyApproved ? Color(hex: "#3478f6") : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(hex: "#3478f6"), lineWidth: 1)
                )
                .cornerRadius(5)
                .pointingHandCursor()
            } else if row.spotifySearchAttempted {
                Text("No match found — edit the title/artist above and click \"Find Spotify Matches\" again")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#eab308"))
            } else {
                Text("Not searched yet")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#52525b"))
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var titleField: some View {
        TextField("Title", text: Binding(get: { row.title }, set: { row.title = $0 }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13, weight: .medium))
    }

    private var artistField: some View {
        TextField("Artist", text: Binding(get: { row.artist }, set: { row.artist = $0 }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11))
    }

    private var bpmField: some View {
        TextField("BPM", text: Binding(get: { row.bpm }, set: { row.bpm = $0 }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
    }

    private var stylePlaceholder: String {
        let lowerRaw = row.rawStyle.lowercased()
        if row.customStyleText.isEmpty, row.resolvedStyles.contains("Other") {
            if lowerRaw.contains("line dance") { return "Type the line dance's name" }
            if lowerRaw.contains("choreography") { return "Type the choreography's name" }
            if lowerRaw.contains("mixer") { return "Type the mixer's name" }
        }
        return "Select styles"
    }

    /// Reuses `Track.formattedStylesDisplay` directly (via a throwaway placeholder Track)
    /// so this column reads exactly like it will on the audience screen — e.g.
    /// Cross-Step Waltz + Jam becomes "Jam (Cross-Step Waltz)".
    private func displayStyleText() -> String {
        let previewTrack = Track(
            url: URL(fileURLWithPath: "/"),
            title: "",
            artist: "",
            danceStyles: row.resolvedStyles,
            customStyle: row.customStyleText,
            duration: 0,
            songHash: ""
        )
        let formatted = previewTrack.formattedStylesDisplay
        return formatted == "—" ? "" : formatted
    }
}
