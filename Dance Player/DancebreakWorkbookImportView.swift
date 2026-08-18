//  DancebreakWorkbookImportView.swift
//  Dance Player

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

    // Re-clicking Confirm skips already-imported rows so local files aren't re-prompted.
    var hasBeenImported: Bool = false

    // The track this row became, so the compliance check can measure real audio length
    // instead of trusting the workbook's Length column.
    var importedTrackID: UUID? = nil
}

// MARK: - Style resolution

/// Only these dropdown labels differ from the app's canonical style names.
private let workbookStyleAliases: [String: String] = [
    "rotary": "Rotary Waltz",
    "cross-step": "Cross-Step Waltz",
    "wcs": "West Coast Swing",
    "nc2s": "Night Club Two Step"
]

/// Left blank instead of echoing the category label, so the DJ types the actual name during review.
private let genericStylePlaceholders: Set<String> = ["line dance", "choreography", "mixer"]

/// Tags for how a song is used rather than what it is. A cross-step waltz danced with a
/// stranger is still a cross-step waltz, so these ride alongside the style.
let workbookRoleTagStyles: Set<String> = ["Jam", "Dance with a Stranger"]

/// Matched anywhere in a Style tag, since DJs write these inline ("Cross-Step with a
/// Stranger", "Rotary (jam)") as often as as their own comma-separated tag.
private let workbookRoleTagKeywords: [(keyword: String, style: String)] = [
    ("stranger", "Dance with a Stranger"),
    ("jam", "Jam"),
]

/// Separators DJs use between two tags in one cell, folded to the comma the dropdown itself
/// uses. None of the predefined styles contain any of these, so splitting on them is safe.
private let workbookTagSeparators = ["/", "+", "&", ";", " - "]

/// Punctuation left around a tag once it's been split out — "Rotary (jam)" leaves "Rotary (".
private let workbookTokenTrimSet = CharacterSet.whitespacesAndNewlines
    .union(CharacterSet(charactersIn: "()[]-–—"))

/// Stripped only as a fallback, after a token fails to resolve as written — "Barbie Line
/// Dance" ends in one of these and must keep it.
private let workbookFillerWords: Set<String> = ["dance", "with", "w", "a", "an", "the", "and"]

/// Whole-word, so "Strangers" or "Jamaica" isn't read as a role tag.
private func removeRoleKeyword(_ keyword: String, from text: inout String) -> Bool {
    var searchStart = text.startIndex
    while let range = text.range(of: keyword, options: .caseInsensitive, range: searchStart..<text.endIndex) {
        let precededByLetter = range.lowerBound > text.startIndex
            && text[text.index(before: range.lowerBound)].isLetter
        let followedByLetter = range.upperBound < text.endIndex
            && text[range.upperBound].isLetter
        if !precededByLetter, !followedByLetter {
            text.removeSubrange(range)
            return true
        }
        searchStart = range.upperBound
    }
    return false
}

private func strippingFillerWords(_ token: String) -> String {
    var words = token.split(separator: " ").map(String.init)
    while let first = words.first, workbookFillerWords.contains(first.lowercased()) { words.removeFirst() }
    while let last = words.last, workbookFillerWords.contains(last.lowercased()) { words.removeLast() }
    return words.joined(separator: " ")
}

private func canonicalWorkbookStyle(for token: String) -> String? {
    if let canonical = workbookStyleAliases[token.lowercased()] { return canonical }
    return predefinedDanceStyles.first { $0.caseInsensitiveCompare(token) == .orderedSame }
}

/// Values come from a fixed dropdown, so there's no typo variance to guard against.
func resolveWorkbookStyles(from rawStyle: String) -> (styles: Set<String>, customText: String) {
    var normalized = rawStyle
    for separator in workbookTagSeparators {
        normalized = normalized.replacingOccurrences(of: separator, with: ",")
    }

    var styles = Set<String>()

    // Pull the role tags out of whichever tag they were written into, keeping what's left of
    // that tag — "Cross-Step with a Stranger" is a cross-step waltz *and* a stranger dance.
    var tokens = normalized
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: workbookTokenTrimSet) }
        .filter { !$0.isEmpty }
        .compactMap { token -> String? in
            var remainder = token
            var foundRoleTag = false
            for (keyword, style) in workbookRoleTagKeywords where removeRoleKeyword(keyword, from: &remainder) {
                styles.insert(style)
                foundRoleTag = true
            }
            guard foundRoleTag else { return token }
            let cleaned = remainder.trimmingCharacters(in: workbookTokenTrimSet)
            return cleaned.isEmpty ? nil : cleaned
        }

    // "Cross-Step" + "Mixer" chosen together means the specific "Cross-Step Waltz Mixer",
    // not the generic Mixer category.
    let crossStepSpellings = ["cross-step", "cross step", "cross-step waltz", "cross step waltz"]
    let lowerTokens = tokens.map { $0.lowercased() }
    let hasCrossStep = lowerTokens.contains { crossStepSpellings.contains($0) }
    let hasMixer = lowerTokens.contains("mixer")
    if hasCrossStep, hasMixer {
        styles.insert("Cross-Step Waltz Mixer")
        tokens.removeAll { (crossStepSpellings + ["mixer"]).contains($0.lowercased()) }
    }

    var leftovers: [String] = []
    for token in tokens {
        if let canonical = canonicalWorkbookStyle(for: token) {
            styles.insert(canonical)
            continue
        }

        // Retry without the connective words a removed role tag leaves behind: "Cross-Step
        // with a Stranger" reaches here as "Cross-Step with a", which is just "Cross-Step".
        let stripped = strippingFillerWords(token)
        if stripped.isEmpty { continue }
        if stripped != token, let canonical = canonicalWorkbookStyle(for: stripped) {
            styles.insert(canonical)
            continue
        }

        leftovers.append(token)
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

/// Matches well-known tracks so they use the shipped local audio instead of asking the DJ to pick one.
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
    ZipArchive.entryData(in: fileURL, named: entryName)
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

/// Best-effort reader: only handles plain single-sheet spreadsheets, not merged cells or special formatting.
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

        // A Popular Edit names the dance, but the workbook's role tags say how it's used —
        // keep those instead of letting the edit's own style list erase them.
        let resolvedStyles = popularEdit
            .map { $0.danceStyles.union(styles.intersection(workbookRoleTagStyles)) } ?? styles

        results.append(
            WorkbookImportRow(
                order: Int(field(row, map.order)),
                title: title,
                artist: artist,
                bpm: field(row, map.bpm),
                lengthText: field(row, map.length),
                rawStyle: rawStyle,
                isLocal: popularEdit != nil ? true : isEditedTrue,
                resolvedStyles: resolvedStyles,
                customStyleText: popularEdit != nil ? "" : customText,
                matchedPopularEdit: popularEdit
            )
        )
    }

    var ordered = results.sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
    promoteClosingStyles(in: &ordered)
    return ordered
}

/// The dropdown has no "Last …" option, so the final occurrence of each closing dance is promoted on import.
private let closingStylePromotions: [(base: String, last: String)] = [
    ("West Coast Swing", "Last West Coast Swing"),
    ("Lindy Hop", "Last Lindy Hop"),
    ("Cross-Step Waltz", "Last Cross-Step Waltz"),
    ("Rotary Waltz", "Last Rotary Waltz"),
]

private let rotaryCloseStyles: Set<String> = ["Rotary Waltz", "Last Rotary Waltz"]

/// The guidelines close on four dances ending in a rotary waltz — so the last four songs,
/// or five when a solo-jazz dance follows the rotary and would push it out of range.
private func closingBlockStart(in rows: [WorkbookImportRow]) -> Int {
    let endsOnRotary = !(rows.last?.resolvedStyles.isDisjoint(with: rotaryCloseStyles) ?? true)
    return max(0, rows.count - (endsOnRotary ? 4 : 5))
}

/// Every guideline category counts a "Last …" tag as its base style, so nothing stops counting.
func promoteClosingStyles(in rows: inout [WorkbookImportRow]) {
    let closingBlockStart = closingBlockStart(in: rows)

    for (base, last) in closingStylePromotions {
        guard let index = rows.lastIndex(where: { $0.resolvedStyles.contains(base) }),
              index >= closingBlockStart
        else { continue }

        rows[index].resolvedStyles.remove(base)
        rows[index].resolvedStyles.insert(last)
    }
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
private let workbookTempoColumnWidth: CGFloat = 66
private let workbookLengthColumnWidth: CGFloat = 70


/// Solid blue, bold white text — used for the primary actions in this flow (Confirm,
/// Find Spotify Matches, Approve) so they read clearly against the dark background.
private struct WorkbookPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// Greys the button out while still letting it be clicked, for actions that need to
    /// explain why they aren't available yet.
    var isMuted: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isMuted ? Color(hex: "#3f3f46") : Color(hex: "#3478f6"))
            .cornerRadius(6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct WorkbookImportReviewView: View {
    @ObservedObject var player: PlayerController
    @State var rows: [WorkbookImportRow]
    var onFinished: () -> Void

    /// Bound to the shared setting so the menu bar, project settings and this bar agree.
    private var spotifyClientID: String {
        get { player.spotifyClientID }
        nonmutating set { player.spotifyClientID = newValue }
    }
    @State private var isImporting = false
    @State private var currentSongIndex = 0
    @State private var currentImportTotal = 0
    @State private var currentImportRowTitle = ""
    @State private var currentImportRowID: UUID? = nil
    @State private var failureSummary: [String] = []

    // Matches are fetched and approved up front, so Confirm just imports what's already approved.
    @State private var isFetchingSpotifyMatches = false
    @State private var spotifyFetchCompletedCount = 0
    @State private var spotifyFetchTotalCount = 0

    // Confirm-time fallback for a row that reaches Confirm with no approved match —
    // rather than just skipping it, let the DJ search or paste a link right there.
    @State private var isPresentingComplianceCheck = false
    @State private var isPresentingImportFirstNotice = false
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
                        WorkbookRowEditor(row: $row, player: player, isActive: isImporting && row.id == currentImportRowID)
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
        .sheet(isPresented: $isPresentingComplianceCheck) {
            GuidelineComplianceSheet(rows: rows, importedMetrics: importedMetrics) {
                isPresentingComplianceCheck = false
            }
        }
        .alert("Import the songs first", isPresented: $isPresentingImportFirstNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Song length is measured from the imported audio, not the workbook's Length column, so every song has to be imported before compliance can be checked.\n\n\(remainingImportCount) song\(remainingImportCount == 1 ? "" : "s") still to import.")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Dancebreak DJ Workbook Import")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                Text(hasImportedEverything
                     ? "\(rows.count) song\(rows.count == 1 ? "" : "s") imported — check compliance if you'd like, then save."
                     : "\(rows.count) song\(rows.count == 1 ? "" : "s") found — review sources and styles, then import.")
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
                TextField("Required when Local File? is unchecked", text: $player.spotifyClientID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button(action: fetchAllSpotifyMatches) {
                    Text(isFetchingSpotifyMatches ? "Finding Matches… \(spotifyFetchCompletedCount)/\(spotifyFetchTotalCount)" : "Find Spotify Matches")
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
                .disabled(isFetchingSpotifyMatches || spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Fetches cover art for every Spotify-marked row up front — review each match below and confirm it before importing. You'll be asked to approve access in your browser the first time.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#52525b"))

            Divider().background(Color(hex: "#242429"))

            // Offered here as well as in Advanced Settings — import is when the workbook's BPM
            // column is in front of the DJ, so it's the natural place to decide.
            Toggle("Detect BPM for local songs on import", isOn: $player.bpmDetectionOnImport)
                .toggleStyle(.switch)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            Text("Only fills rows whose BPM is blank — a tempo typed in the workbook is never "
                 + "overwritten. Measured from the audio, so it needs the local file.")
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
            Text("TEMPO").frame(width: workbookTempoColumnWidth, alignment: .leading)
            Text("LENGTH").frame(width: workbookLengthColumnWidth, alignment: .leading)
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
            .pointingHandCursor()

            Spacer()

            // Stays clickable while greyed out so it can explain why it isn't ready yet.
            Button("Check Guideline Compliance") {
                if hasImportedEverything {
                    isPresentingComplianceCheck = true
                } else {
                    isPresentingImportFirstNotice = true
                }
            }
            .buttonStyle(WorkbookPrimaryButtonStyle(isMuted: !hasImportedEverything))
            .pointingHandCursor()
            .padding(.trailing, 8)

            if hasImportedEverything {
                Button("Save") {
                    onFinished()
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
            } else {
                Button(action: startImport) {
                    Text("Import \(remainingImportCount) Song\(remainingImportCount == 1 ? "" : "s")")
                }
                .buttonStyle(WorkbookPrimaryButtonStyle())
                .pointingHandCursor()
                .disabled(remainingImportCount == 0)
            }
        }
        .padding(16)
    }

    private var remainingImportCount: Int {
        rows.filter { !$0.hasBeenImported }.count
    }

    /// Compliance needs every song's real audio length, so it waits for a complete import.
    private var hasImportedEverything: Bool {
        !rows.isEmpty && remainingImportCount == 0
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

    /// Safe to click again after fixing a title, since already-matched rows are left alone.
    private func fetchAllSpotifyMatches() {
        let clientID = spotifyClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { return }

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
        // Skip already-imported rows so re-clicking Confirm doesn't re-prompt local file pickers.
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
                let trackCountBefore = await MainActor.run { player.tracks.count }
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
                    await MainActor.run { markImported(index, since: trackCountBefore) }
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
                        await MainActor.run { markImported(index, since: trackCountBefore) }
                    } else {
                        await MainActor.run {
                            failureSummary.append("\(row.title) — no file selected, skipped")
                        }
                    }
                } else if let match = row.spotifyMatch, row.isSpotifyApproved {
                    await player.importWorkbookSpotifyMatch(
                        match,
                        title: row.title,
                        artist: row.artist,
                        danceStyles: row.resolvedStyles,
                        customStyle: row.customStyleText,
                        manualBPM: row.bpm
                    )
                    await MainActor.run { markImported(index, since: trackCountBefore) }
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
                            title: row.title,
                            artist: row.artist,
                            danceStyles: row.resolvedStyles,
                            customStyle: row.customStyleText,
                            manualBPM: row.bpm
                        )
                        await MainActor.run { markImported(index, since: trackCountBefore) }
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
            }
        }
    }

    /// Records which track a row became. Imports append exactly one track on success, so a
    /// count that didn't grow means the import silently failed and there's nothing to link.
    private func markImported(_ index: Int, since trackCountBefore: Int) {
        rows[index].hasBeenImported = true
        if player.tracks.count > trackCountBefore, let imported = player.tracks.last {
            rows[index].importedTrackID = imported.id
            // The imported song named itself, so the row must follow to avoid disagreeing with the queue.
            rows[index].title = imported.title
            rows[index].artist = imported.artist
        }
    }

    /// Length is measured from the real imported audio, not the workbook's Length column.
    private var importedMetrics: [UUID: ImportedSongMetrics] {
        var metrics: [UUID: ImportedSongMetrics] = [:]
        for row in rows {
            guard let trackID = row.importedTrackID,
                  let track = player.tracks.first(where: { $0.id == trackID })
            else { continue }
            metrics[row.id] = ImportedSongMetrics(
                playingMinutes: track.effectiveDuration / 60.0,
                speedMultiplier: track.speedMultiplier
            )
        }
        return metrics
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
                    .pointingHandCursor()
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
                .pointingHandCursor()
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
        // Toggling isPresented true again too quickly can silently fail to re-show the sheet.
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
    @ObservedObject var player: PlayerController
    var isActive: Bool

    @State private var isShowingStylePicker = false
    @State private var isShowingSongEditor = false
    /// Artwork for a row matched to a bundled Popular Edit, so it's visible before import.
    @State private var bundledArtwork: NSImage? = nil

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
        .task(id: row.matchedPopularEdit?.id) {
            guard let edit = row.matchedPopularEdit else {
                bundledArtwork = nil
                return
            }
            // `load` returns the cached image immediately when there is one.
            bundledArtwork = await PopularEditArtwork.load(for: edit)
        }
    }

    private var mainRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.order != nil ? "\(row.order!)" : "—")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#71717a"))
                .frame(width: workbookOrderColumnWidth, alignment: .leading)

            songCell
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

            tempoCell
                .frame(width: workbookTempoColumnWidth, alignment: .leading)

            lengthCell
                .frame(width: workbookLengthColumnWidth, alignment: .leading)

            Button("Edit") { isShowingSongEditor = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .sheet(isPresented: $isShowingSongEditor) {
            WorkbookSongEditorSheet(row: $row, player: player) {
                isShowingSongEditor = false
            }
        }
    }

    /// Long titles truncate rather than pushing the rest of the row out of alignment.
    private var songCell: some View {
        HStack(spacing: 8) {
            Group {
                if let artwork = importedArtwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(hex: "#18181b")
                        Image(systemName: "music.note")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#52525b"))
                    }
                }
            }
            .frame(width: 34, height: 34)
            .cornerRadius(4)
            .clipped()

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.title)
                Text(row.artist)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#71717a"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.artist)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var spotifyMatchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Spacer().frame(width: workbookOrderColumnWidth + 12)
                Text("Importing from Spotify:")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                Spacer()
            }

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
                            Text(row.isSpotifyApproved ? "Import Confirmed" : "Confirm Import")
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
                    Text("No match found — fix the title/artist under Edit, then click \"Find Spotify Matches\" again")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#eab308"))
                } else {
                    Text("Not searched yet")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#52525b"))
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private var bpmField: some View {
        TextField("BPM", text: Binding(get: { row.bpm }, set: { row.bpm = $0 }))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
    }

    // MARK: Length & tempo readouts

    private var importedTrack: Track? {
        guard let trackID = row.importedTrackID else { return nil }
        return player.tracks.first { $0.id == trackID }
    }

    private var importedArtwork: NSImage? {
        importedTrack?.artwork ?? row.spotifyMatch?.artwork ?? bundledArtwork
    }

    /// Shown as a percentage of normal speed, so an untouched song reads 100%.
    private var tempoCell: some View {
        Text(String(format: "%g%%", 100 + (importedTrack?.tempoPercentage ?? 0)))
            .font(.system(size: 12))
            .foregroundColor(importedTrack == nil ? Color(hex: "#52525b") : .white)
    }

    private var lengthCell: some View {
        Group {
            if let track = importedTrack {
                Text(Self.formatDuration(track.effectiveDuration))
                    .foregroundColor(.white)
            } else {
                Text(row.lengthText.isEmpty ? "—" : row.lengthText)
                    .foregroundColor(Color(hex: "#52525b"))
                    .help("Workbook length — import the song to measure the real one")
            }
        }
        .font(.system(size: 12))
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

    /// Reuses `Track.formattedStylesDisplay` so this column reads exactly like the audience screen will.
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

// MARK: - Song Editor

/// Everything but title/artist needs the imported track, so it stays disabled until the song is in.
struct WorkbookSongEditorSheet: View {
    @Binding var row: WorkbookImportRow
    @ObservedObject var player: PlayerController
    var onDismiss: () -> Void

    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var startMinutes: String = "0"
    @State private var startSeconds: String = "00"
    @State private var endMinutes: String = "0"
    @State private var endSeconds: String = "00"
    /// Offset from normal speed, matching `Track.tempoPercentage` (0 = untouched).
    @State private var tempoOffset: Double = 0
    @State private var isEditingPercentText = false
    @State private var percentTextInput = ""
    @State private var isEditingBPMText = false
    @State private var bpmTextInput = ""
    @State private var artwork: NSImage? = nil
    @State private var didChooseArtwork = false

    private var trackIndex: Int? {
        guard let trackID = row.importedTrackID else { return nil }
        return player.tracks.firstIndex { $0.id == trackID }
    }

    private var isImported: Bool { trackIndex != nil }

    private var canRetime: Bool {
        guard let index = trackIndex else { return false }
        return player.tracks[index].source == .local
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Song")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .padding(16)

            Divider().background(Color(hex: "#242429"))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    artworkWell

                    labelled("SONG TITLE") {
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                    }

                    labelled("ARTIST NAME") {
                        TextField("Artist", text: $artist)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !isImported {
                        Text("Import the song to trim it or change its tempo.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#71717a"))
                    }

                    Divider().background(Color(hex: "#242429"))

                    labelled("START TIMESTAMP") {
                        timestampRow(minutes: $startMinutes, seconds: $startSeconds)
                    }
                    .opacity(isImported ? 1 : 0.4)

                    labelled("END TIMESTAMP") {
                        timestampRow(minutes: $endMinutes, seconds: $endSeconds)
                    }
                    .opacity(isImported ? 1 : 0.4)

                    tempoSection
                        .opacity(canRetime ? 1 : 0.4)

                    if isImported, !canRetime {
                        Text("Tempo can't be changed on Spotify playback.")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#71717a"))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color(hex: "#242429"))

            HStack {
                Button("Cancel", action: onDismiss)
                    .buttonStyle(.bordered)
                    .pointingHandCursor()
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .pointingHandCursor()
            }
            .padding(16)
        }
        .frame(width: 420, height: 560)
        .background(Color(hex: "#0e0e10"))
        .onAppear(perform: load)
    }

    /// Mirrors the main player's tempo control: a slider you can drive either by percentage
    /// or by target BPM, whichever the DJ is thinking in.
    private var tempoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TEMPO")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)

                Spacer()

                if isEditingPercentText {
                    TextField("100", text: $percentTextInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .font(.system(size: 11, weight: .bold))
                        .onSubmit(commitPercentText)
                        .onExitCommand { isEditingPercentText = false }
                } else {
                    Text(String(format: "%.1f%%", 100 + tempoOffset))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(tempoOffset == 0 ? .gray : .blue)
                        .help("Click to type a percentage")
                        .onTapGesture {
                            percentTextInput = String(format: "%.1f", 100 + tempoOffset)
                            isEditingPercentText = true
                        }
                }

                if isEditingBPMText {
                    TextField("BPM", text: $bpmTextInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                        .font(.system(size: 11, weight: .bold))
                        .onSubmit(commitBPMText)
                        .onExitCommand { isEditingBPMText = false }
                } else if let effective = effectiveBPM {
                    Text("\(Int(effective.rounded())) BPM")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.blue)
                        .help("Click to type a target BPM")
                        .onTapGesture {
                            bpmTextInput = String(Int(effective.rounded()))
                            isEditingBPMText = true
                        }
                }
            }

            TicklessSlider(
                value: $tempoOffset,
                range: -25...25,
                step: tempoSliderStep,
                onEditingChanged: { _ in }
            )
            .accentColor(.blue)
            .disabled(!canRetime)

            HStack {
                Text("Slower")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                Spacer()
                Button("Reset") { tempoOffset = 0 }
                    .font(.system(size: 9))
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                Spacer()
                Text("Faster")
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
            }
        }
    }

    /// The row's workbook BPM is the base the slider scales.
    private var baseBPM: Double? {
        guard let value = Double(row.bpm.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return nil }
        return value
    }

    private var effectiveBPM: Double? {
        baseBPM.map { $0 * (1 + tempoOffset / 100) }
    }

    /// Whole-BPM steps when there's a base BPM to snap to, else the default 0.5%.
    private var tempoSliderStep: Double {
        guard let base = baseBPM, base > 0 else { return 0.5 }
        return max(0.02, 100.0 / base)
    }

    private func commitPercentText() {
        if let typed = Double(percentTextInput.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) {
            tempoOffset = max(-25, min(25, typed - 100))
        }
        isEditingPercentText = false
    }

    private func commitBPMText() {
        if let target = Double(bpmTextInput.trimmingCharacters(in: .whitespaces)),
           let base = baseBPM, base > 0, target > 0 {
            tempoOffset = max(-25, min(25, (target / base - 1) * 100))
        }
        isEditingBPMText = false
    }

    private var artworkWell: some View {
        VStack(spacing: 6) {
            Group {
                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color(hex: "#18181b")
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: 110, height: 110)
            .cornerRadius(8)
            .clipped()
            .onTapGesture { if isImported { importCoverArt() } }
            .pointingHandCursor()

            Text(isImported ? "Click the image to change the cover art" : "Cover art is available once the song is imported")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .opacity(isImported ? 1 : 0.5)
    }

    private func labelled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.gray)
            content()
        }
    }

    private func timestampRow(minutes: Binding<String>, seconds: Binding<String>) -> some View {
        HStack(spacing: 6) {
            TextField("Min", text: minutes)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
            Text(":").font(.system(size: 12, weight: .bold))
            TextField("Sec", text: seconds)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
        }
        .disabled(!isImported)
    }

    private func load() {
        title = row.title
        artist = row.artist

        guard let index = trackIndex else { return }
        let track = player.tracks[index]
        artwork = track.artwork
        tempoOffset = track.tempoPercentage

        let start = Int(track.startTime.rounded())
        startMinutes = "\(start / 60)"
        startSeconds = String(format: "%02d", start % 60)

        let end = Int((track.endTime ?? track.duration).rounded())
        endMinutes = "\(end / 60)"
        endSeconds = String(format: "%02d", end % 60)
    }

    private func save() {
        row.title = title
        row.artist = artist

        if let index = trackIndex {
            var track = player.tracks[index]
            track.title = title
            track.artist = artist
            track.artwork = artwork
            if didChooseArtwork { track.hasCustomArtwork = true }

            let start = (Double(startMinutes) ?? 0) * 60 + (Double(startSeconds) ?? 0)
            let end = (Double(endMinutes) ?? 0) * 60 + (Double(endSeconds) ?? 0)
            let previousStart = track.startTime

            // Only apply fields the DJ actually retyped, since these are rounded to whole seconds.
            if start != Double(Int(previousStart.rounded())) {
                track.startTime = max(0, min(start, track.duration))
            }
            if end != Double(Int((track.endTime ?? track.duration).rounded())) {
                track.endTime = (end > track.startTime && end < track.duration) ? end : nil
            }

            if track.source == .local {
                track.tempoPercentage = tempoOffset
            }

            player.tracks[index] = track
            if player.currentIndex == index {
                player.synchronizeActiveTrackSettings()
                player.recueForTrimChange(previousStartTime: previousStart)
            }
            player.saveTrack(track)
        }

        onDismiss()
    }

    private func importCoverArt() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .png, .jpeg]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        artwork = image
        didChooseArtwork = true
    }
}
