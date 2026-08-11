//
//  GuidelineComplianceView.swift
//  Dance Player
//
//  Checks a parsed Dancebreak DJ Workbook against the published DJ Guidelines
//  (https://dancebreak.stanford.edu/info/djing/).
//

import SwiftUI

// MARK: - Lesson categories

/// The guidelines table has three columns; which one applies depends on the lesson style.
enum LessonColumn: String {
    case waltz = "Waltz Lesson"
    case swing = "Swing Lesson"
    case other = "Other Lesson"

    /// A set is a waltz set if the lesson is rotary or cross-step waltz, and a swing set if
    /// it's lindy hop or west coast swing.
    static func forLesson(style: String) -> LessonColumn {
        switch style {
        case "Rotary Waltz", "Cross-Step Waltz": return .waltz
        case "Lindy Hop", "West Coast Swing": return .swing
        default: return .other
        }
    }

    func pick(_ waltzValue: Int, _ swingValue: Int, _ otherValue: Int) -> Int {
        switch self {
        case .waltz: return waltzValue
        case .swing: return swingValue
        case .other: return otherValue
        }
    }
}

/// Styles the DJ can pick as the lesson style — the "Last …" variants, Jam, Dance with a
/// Stranger and Other are sequence/role tags rather than something a lesson teaches.
let guidelineLessonStyles: [String] = predefinedDanceStyles.filter {
    !$0.hasPrefix("Last ") && $0 != "Jam" && $0 != "Dance with a Stranger" && $0 != "Other"
}

// MARK: - Style groupings

/// A guidelines table row. Matching falls back to the raw workbook Style text because the
/// spreadsheet's "Line Dance", "Choreography" and "Mixer" options are umbrella categories
/// that resolve to "Other" unless the song is one of the bundled Popular Edits.
struct StyleCategory {
    let styles: Set<String>
    let rawKeywords: [String]

    init(_ styles: Set<String>, rawKeywords: [String] = []) {
        self.styles = styles
        self.rawKeywords = rawKeywords
    }

    func matches(_ row: WorkbookImportRow) -> Bool {
        if !row.resolvedStyles.isDisjoint(with: styles) { return true }
        guard !rawKeywords.isEmpty else { return false }
        let raw = row.rawStyle.lowercased()
        return rawKeywords.contains { raw.contains($0) }
    }
}

private enum StyleGroup {
    // A cross-step waltz mixer satisfies the mixer row *and* the cross-step waltz row — the
    // floor is still dancing a cross-step waltz to it.
    static let crossStepWaltz = StyleCategory(["Cross-Step Waltz", "Last Cross-Step Waltz", "Cross-Step Waltz Mixer"])
    static let fastWaltz = StyleCategory(["Fast Waltz", "Accelerating Waltz"])
    static let rotaryWaltz = StyleCategory(["Rotary Waltz", "Last Rotary Waltz", "Fast Waltz", "Accelerating Waltz"])
    static let lindyHop = StyleCategory(["Lindy Hop", "Last Lindy Hop"])
    static let westCoastSwing = StyleCategory(["West Coast Swing", "Last West Coast Swing"])
    static let polka = StyleCategory(["Polka"])
    static let fusion = StyleCategory(["Fusion"])
    static let latin = StyleCategory(["Bachata", "Cha-Cha", "Salsa", "Tango"])
    static let lineDance = StyleCategory(
        ["Barbie Line Dance", "Shivers Line Dance", "Tokyo Polka"],
        rawKeywords: ["line dance"]
    )
    static let mixer = StyleCategory(
        ["Cross-Step Waltz Mixer", "'T Smidje Mixer"],
        rawKeywords: ["mixer"]
    )
    static let choreography = StyleCategory(
        ["Bohemian National Polka", "Romany Polka", "Dawn Mazurka"],
        rawKeywords: ["choreograph"]
    )
    static let jam = StyleCategory(["Jam"])
    static let danceWithAStranger = StyleCategory(["Dance with a Stranger"])

    /// Everything the guidelines table names explicitly. Anything else counts against the
    /// "additional non-core dance style" maximum.
    static let core: [StyleCategory] = [
        crossStepWaltz, rotaryWaltz, lindyHop, westCoastSwing, polka, fusion,
        latin, lineDance, mixer, choreography, jam, danceWithAStranger,
    ]

    /// Styles that can close the set — a plain rotary waltz counts, since the workbook has
    /// no "Last …" tag. Fast/accelerating waltzes are deliberately excluded.
    static let rotaryClose = StyleCategory(["Rotary Waltz", "Last Rotary Waltz"])

    /// The four core dances the set must end with, in the order the guidelines list them.
    static let closingStyles: [(label: String, category: StyleCategory)] = [
        ("west coast swing", westCoastSwing),
        ("lindy hop", lindyHop),
        ("cross-step waltz", crossStepWaltz),
        ("rotary waltz", rotaryClose),
    ]
}

/// Extended (not "sweet spot") BPM ranges — the guidelines allow anything inside these.
private let extendedTempoRanges: [String: ClosedRange<Double>] = [
    "Cross-Step Waltz": 105...125,
    "Last Cross-Step Waltz": 105...125,
    "Cross-Step Waltz Mixer": 105...125,
    "Rotary Waltz": 135...160,
    "Last Rotary Waltz": 135...160,
    "Fast Waltz": 170...200,
    "Lindy Hop": 125...160,
    "Last Lindy Hop": 125...160,
    "West Coast Swing": 90...120,
    "Last West Coast Swing": 90...120,
    "Polka": 105...130,
]

// MARK: - Report model

/// What the compliance check needs from an imported track: how long it will actually play,
/// and the tempo adjustment applied to it (which shifts the song's effective BPM).
struct ImportedSongMetrics {
    var playingMinutes: Double
    var speedMultiplier: Double
}

struct GuidelineCheck: Identifiable {
    let id = UUID()
    let label: String
    let detail: String
    let passes: Bool
    /// Songs responsible for a failure, so the DJ knows what to go fix.
    var offenders: [String] = []
}

struct GuidelineSection: Identifiable {
    let id = UUID()
    let title: String
    let checks: [GuidelineCheck]
}

struct GuidelineReport {
    var sections: [GuidelineSection]

    var allChecks: [GuidelineCheck] { sections.flatMap(\.checks) }
    var failures: Int { allChecks.filter { !$0.passes }.count }
    var passes: Int { allChecks.filter(\.passes).count }
    var isCompliant: Bool { failures == 0 }
}

// MARK: - Parsing helpers

/// Workbook "Length" cells are usually `m:ss`, but a plain number shows up too. Values that
/// look too large to be minutes are read as seconds.
func parseWorkbookMinutes(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.contains(":") {
        let parts = trimmed.split(separator: ":").map { Double($0) }
        guard parts.count == 2, let minutes = parts[0], let seconds = parts[1] else { return nil }
        return minutes + seconds / 60.0
    }

    guard let value = Double(trimmed), value > 0 else { return nil }
    return value > 20 ? value / 60.0 : value
}

private func parseBPM(_ text: String) -> Double? {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Double(cleaned), value > 0 else { return nil }
    return value
}

// MARK: - Evaluation

struct GuidelineEvaluator {
    let rows: [WorkbookImportRow]
    /// Measurements per row id, taken from the imported audio.
    let importedMetrics: [UUID: ImportedSongMetrics]
    let lessonStyle: String
    let setHours: Double

    private var column: LessonColumn { .forLesson(style: lessonStyle) }

    /// Requirements are written for a 2-hour set and scale with length. Minimums round down
    /// and maximums round up, so scaling never makes a guideline stricter than stated —
    /// a 3-hour waltz set needs 10 of the lesson style, not 10.5.
    private var scale: Double { setHours / 2.0 }

    private func scaledMinimum(_ base: Int) -> Int {
        max(0, Int(floor(Double(base) * scale + 1e-9)))
    }

    private func scaledMaximum(_ base: Int) -> Int {
        Int(ceil(Double(base) * scale - 1e-9))
    }

    /// Counts the lesson style the same way its own table row does, so a cross-step waltz
    /// lesson doesn't report one total here and a different one below. Narrower categories
    /// come first — a cross-step waltz mixer lesson means mixers, not every cross-step waltz.
    private var lessonCategory: StyleCategory {
        for category in [StyleGroup.mixer, StyleGroup.lineDance, StyleGroup.choreography,
                         StyleGroup.crossStepWaltz, StyleGroup.rotaryWaltz, StyleGroup.lindyHop,
                         StyleGroup.westCoastSwing, StyleGroup.polka, StyleGroup.latin, StyleGroup.fusion]
        where category.styles.contains(lessonStyle) {
            return category
        }
        return StyleCategory([lessonStyle])
    }

    private func count(_ category: StyleCategory, in slice: [WorkbookImportRow]? = nil) -> Int {
        (slice ?? rows).filter(category.matches).count
    }

    private func indices(matching category: StyleCategory) -> [Int] {
        rows.indices.filter { category.matches(rows[$0]) }
    }

    private func minimumCheck(_ label: String, category: StyleCategory, base: Int) -> GuidelineCheck {
        let required = scaledMinimum(base)
        let actual = count(category)
        return GuidelineCheck(
            label: label,
            detail: "\(actual) of minimum \(required)",
            passes: actual >= required
        )
    }

    func evaluate() -> GuidelineReport {
        GuidelineReport(sections: [
            styleCountSection(),
            placementSection(),
            lengthAndTempoSection(),
            finalSequenceSection(),
        ])
    }

    // MARK: Song selection counts

    private func styleCountSection() -> GuidelineSection {
        var checks: [GuidelineCheck] = [
            minimumCheck("Lesson style — \(lessonStyle)",
                         category: lessonCategory,
                         base: column.pick(7, 7, 5)),
            minimumCheck("Cross-step waltz", category: StyleGroup.crossStepWaltz, base: column.pick(9, 8, 8)),
            minimumCheck("Rotary waltz", category: StyleGroup.rotaryWaltz, base: column.pick(7, 6, 6)),
            minimumCheck("Lindy hop", category: StyleGroup.lindyHop, base: column.pick(4, 4, 3)),
            minimumCheck("West coast swing", category: StyleGroup.westCoastSwing, base: column.pick(4, 4, 3)),
            minimumCheck("Polka", category: StyleGroup.polka, base: 1),
            minimumCheck("Fusion", category: StyleGroup.fusion, base: 1),
            minimumCheck("Latin", category: StyleGroup.latin, base: 1),
            minimumCheck("Line dance", category: StyleGroup.lineDance, base: 1),
            minimumCheck("Mixer", category: StyleGroup.mixer, base: 1),
            minimumCheck("Choreography (BNP etc.)", category: StyleGroup.choreography, base: 1),
        ]

        let fastCount = count(StyleGroup.fastWaltz)
        let fastLimit = scaledMaximum(3)
        checks.append(GuidelineCheck(
            label: "Fast / accelerating waltzes",
            detail: "\(fastCount) of maximum \(fastLimit)",
            passes: fastCount <= fastLimit,
            offenders: fastCount <= fastLimit ? [] : indices(matching: StyleGroup.fastWaltz).map(songLabel)
        ))

        let nonCoreIndices = rows.indices.filter { index in
            let row = rows[index]
            return !row.resolvedStyles.isEmpty && !StyleGroup.core.contains { $0.matches(row) }
        }
        let nonCoreCount = nonCoreIndices.count
        let nonCoreLimit = scaledMaximum(4)
        checks.append(GuidelineCheck(
            label: "Additional non-core styles",
            detail: "\(nonCoreCount) of maximum \(nonCoreLimit)",
            passes: nonCoreCount <= nonCoreLimit,
            offenders: nonCoreCount <= nonCoreLimit ? [] : nonCoreIndices.map(songLabel)
        ))

        let lowerTotal = scaledMinimum(30)
        let upperTotal = scaledMaximum(35)
        checks.append(GuidelineCheck(
            label: "Total songs",
            detail: "\(rows.count) — expected \(lowerTotal)–\(upperTotal)",
            passes: rows.count >= lowerTotal && rows.count <= upperTotal
        ))

        return GuidelineSection(title: "Song Selection", checks: checks)
    }

    // MARK: Placement within the set

    private func placementSection() -> GuidelineSection {
        let firstFive = Array(rows.prefix(5))
        let lessonInFirstFive = count(lessonCategory, in: firstFive)

        let midpoint = rows.count / 2
        let firstHalf = Array(rows.prefix(midpoint))
        let secondHalf = Array(rows.suffix(rows.count - midpoint))

        let strangerCount = count(StyleGroup.danceWithAStranger, in: firstHalf)
        let jamCount = count(StyleGroup.jam, in: secondHalf)

        return GuidelineSection(title: "Placement", checks: [
            GuidelineCheck(
                label: "Lesson style in first 5 songs",
                detail: "\(lessonInFirstFive) of minimum 2",
                passes: lessonInFirstFive >= 2
            ),
            GuidelineCheck(
                label: "Dance with a Stranger in first half",
                detail: "\(strangerCount) of minimum 1",
                passes: strangerCount >= 1
            ),
            GuidelineCheck(
                label: "Jam in second half",
                detail: "\(jamCount) of minimum 1",
                passes: jamCount >= 1
            ),
        ])
    }

    // MARK: Length, tempo, and the exception allowance

    /// How long the song will actually play, from the imported audio — the workbook's Length
    /// column is only a fallback for a row that somehow has no imported track.
    private func playingMinutes(for row: WorkbookImportRow) -> Double? {
        if let metrics = importedMetrics[row.id] { return metrics.playingMinutes }
        return parseWorkbookMinutes(row.lengthText)
    }

    /// BPM as it will actually be heard — speeding a track up raises its tempo, which is
    /// how a DJ pulls an out-of-range song back into its style's window.
    private func effectiveBPM(for row: WorkbookImportRow) -> Double? {
        guard let bpm = parseBPM(row.bpm) else { return nil }
        return bpm * (importedMetrics[row.id]?.speedMultiplier ?? 1.0)
    }

    private func songLabel(_ index: Int) -> String {
        "\(index + 1). \(rows[index].title)"
    }

    private func formatMinutes(_ minutes: Double) -> String {
        let total = Int((minutes * 60.0).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Indices of songs breaking a length or tempo guideline — the guidelines treat these
    /// together as the set's allowed "exceptions".
    private func violationIndices() -> (length: [Int], tempo: [Int]) {
        var lengthViolations: [Int] = []
        var tempoViolations: [Int] = []

        for (index, row) in rows.enumerated() {
            if let minutes = playingMinutes(for: row) {
                // The limit itself is allowed — 4:30 is fine, 4:31 isn't.
                let limit = index < 10 ? 3.5 : 4.5
                if minutes > limit + 1e-6 { lengthViolations.append(index) }
            }

            if let bpm = effectiveBPM(for: row) {
                // Only styles with a published range can be judged; a song tagged with
                // several styles passes if it fits any one of them.
                let ranges = row.resolvedStyles.compactMap { extendedTempoRanges[$0] }
                if !ranges.isEmpty, !ranges.contains(where: { $0.contains(bpm) }) {
                    tempoViolations.append(index)
                }
            }
        }

        return (lengthViolations, tempoViolations)
    }

    /// Being outside the extended tempo range or over the length limit isn't a failure in
    /// itself — the whole extended range is allowed, and a set may carry up to 6 such songs.
    /// What's checked is the budget: how many, and where they sit.
    private func lengthAndTempoSection() -> GuidelineSection {
        let (lengthViolations, tempoViolations) = violationIndices()
        let exceptions = Set(lengthViolations).union(tempoViolations).sorted()

        func reason(_ index: Int) -> String {
            var parts: [String] = []

            if lengthViolations.contains(index) {
                let played = playingMinutes(for: rows[index]).map { formatMinutes($0) } ?? "?"
                parts.append("\(played), over the \(index < 10 ? "3:30" : "4:30") limit")
            }

            if tempoViolations.contains(index) {
                let row = rows[index]
                let bpm = effectiveBPM(for: row).map { String(format: "%.0f BPM", $0) } ?? "unknown BPM"
                let ranges = row.resolvedStyles
                    .compactMap { style in
                        extendedTempoRanges[style].map { "\(style) \(Int($0.lowerBound))–\(Int($0.upperBound))" }
                    }
                    .sorted()
                    .joined(separator: ", ")
                parts.append("\(bpm), outside \(ranges)")
            }

            return "\(songLabel(index)) — \(parts.joined(separator: "; "))"
        }

        let exceptionLimit = scaledMaximum(6)
        var checks: [GuidelineCheck] = [
            GuidelineCheck(
                label: "Songs using a length/tempo exception",
                detail: "\(exceptions.count) of maximum \(exceptionLimit)",
                passes: exceptions.count <= exceptionLimit,
                offenders: exceptions.map(reason)
            )
        ]

        let earlyExceptions = exceptions.filter { $0 < 10 }
        checks.append(GuidelineCheck(
            label: "No exceptions in first 10 songs",
            detail: earlyExceptions.isEmpty ? "None" : "\(earlyExceptions.count) in the opening block",
            passes: earlyExceptions.isEmpty,
            offenders: earlyExceptions.map(songLabel)
        ))

        let consecutivePairs = zip(exceptions, exceptions.dropFirst()).filter { $1 == $0 + 1 }
        checks.append(GuidelineCheck(
            label: "No consecutive exceptions",
            detail: consecutivePairs.isEmpty ? "None adjacent" : "\(consecutivePairs.count) back-to-back",
            passes: consecutivePairs.isEmpty,
            offenders: consecutivePairs.map { "\(songLabel($0)) then \(songLabel($1))" }
        ))

        return GuidelineSection(title: "Length & Tempo Exceptions", checks: checks)
    }

    // MARK: Closing sequence

    private func finalSequenceSection() -> GuidelineSection {
        // The workbook's Style column has no "Last …" option — the closing dances are just
        // tagged with their style — so the closing block is identified by position.
        // A solo-jazz closing dance may optionally follow the final rotary waltz.
        func isRotaryClose(_ row: WorkbookImportRow) -> Bool {
            StyleGroup.rotaryClose.matches(row)
        }

        var closingIndex: Int? = nil
        if let last = rows.indices.last, isRotaryClose(rows[last]) {
            closingIndex = last
        } else if rows.count >= 2, isRotaryClose(rows[rows.count - 2]) {
            closingIndex = rows.count - 2
        }

        guard let closingIndex else {
            return GuidelineSection(title: "Final Sequence", checks: [
                GuidelineCheck(
                    label: "Set ends on a rotary waltz",
                    detail: rows.isEmpty ? "No songs" : "Final song is not a rotary waltz",
                    passes: false
                ),
                GuidelineCheck(
                    label: "Closing sequence complete",
                    detail: "No closing rotary waltz to anchor the sequence",
                    passes: false
                ),
            ])
        }

        let trailing = rows.count - 1 - closingIndex
        var checks: [GuidelineCheck] = [
            GuidelineCheck(
                label: "Set ends on a rotary waltz",
                detail: trailing == 0 ? "Final song" : "Followed by 1 closing dance",
                passes: true
            )
        ]

        let closingBlock = Array(rows[max(0, closingIndex - 3)...closingIndex])
        let missing = StyleGroup.closingStyles
            .filter { entry in !closingBlock.contains(where: entry.category.matches) }
            .map(\.label)

        checks.append(GuidelineCheck(
            label: "Closing sequence complete",
            detail: missing.isEmpty
                ? "Ends with west coast swing, lindy hop, cross-step and rotary waltz"
                : "Missing \(missing.joined(separator: ", "))",
            passes: missing.isEmpty
        ))

        return GuidelineSection(title: "Final Sequence", checks: checks)
    }
}

// MARK: - View

struct GuidelineComplianceSheet: View {
    let rows: [WorkbookImportRow]
    let importedMetrics: [UUID: ImportedSongMetrics]
    var onDismiss: () -> Void

    @State private var lessonStyle: String = "Cross-Step Waltz"
    @State private var setHours: Double = 2.0

    private var report: GuidelineReport {
        GuidelineEvaluator(
            rows: rows,
            importedMetrics: importedMetrics,
            lessonStyle: lessonStyle,
            setHours: setHours
        ).evaluate()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color(hex: "#242429"))
            controls
            Divider().background(Color(hex: "#242429"))
            summary
            Divider().background(Color(hex: "#242429"))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(report.sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title.uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(Color(hex: "#71717a"))
                                .tracking(0.6)

                            ForEach(section.checks) { check in
                                checkRow(check)
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().background(Color(hex: "#242429"))

            HStack {
                Spacer()
                Button("Done", action: onDismiss)
                    .buttonStyle(GuidelinePrimaryButtonStyle())
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .background(Color(hex: "#0e0e10"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Guideline Compliance")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text("Checked against the Dancebreak DJ Guidelines for a \(formattedHours) set.")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "#71717a"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var controls: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text("Lesson Style")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                Picker("", selection: $lessonStyle) {
                    ForEach(guidelineLessonStyles, id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            HStack(spacing: 8) {
                Text("Set Length")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: "#a3a3ac"))
                Stepper(value: $setHours, in: 0.5...8.0, step: 0.5) {
                    Text(formattedHours)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                .frame(width: 130)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        let report = self.report
        return HStack(spacing: 10) {
            Circle()
                .fill(report.isCompliant ? Color(hex: "#22c55e") : Color(hex: "#eab308"))
                .frame(width: 10, height: 10)
            Text(report.isCompliant
                 ? "Meets all \(report.allChecks.count) guidelines for a \(LessonColumn.forLesson(style: lessonStyle).rawValue.lowercased())."
                 : "\(report.failures) of \(report.allChecks.count) guidelines not met.")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func checkRow(_ check: GuidelineCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: check.passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(check.passes ? Color(hex: "#22c55e") : Color(hex: "#eab308"))
                    .font(.system(size: 12))
                Text(check.label)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                Spacer(minLength: 12)
                Text(check.detail)
                    .font(.system(size: 11))
                    .foregroundColor(check.passes ? Color(hex: "#71717a") : Color(hex: "#eab308"))
            }

            // Listed even when the check passes, so the DJ can see which songs are
            // spending the exception budget.
            if !check.offenders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(check.offenders, id: \.self) { offender in
                        Text(offender)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#a3a3ac"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var formattedHours: String {
        setHours == floor(setHours)
            ? "\(Int(setHours)) hour\(setHours == 1 ? "" : "s")"
            : String(format: "%.1f hours", setHours)
    }
}

/// Matches the blue primary buttons used throughout the workbook import flow.
private struct GuidelinePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color(hex: "#3478f6"))
            .cornerRadius(6)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
