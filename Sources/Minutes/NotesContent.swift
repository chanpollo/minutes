import AppKit
import SwiftUI

extension Font {
    /// Summary and transcript text; 13 pt sets Thai too small for long reading.
    static let reading = Font.system(size: 14)
}

private var inlineCache: [String: AttributedString] = [:]

/// Parsed once per string; views showing the summary are drawn again on every player tick.
private func inline(_ text: String) -> AttributedString {
    if let cached = inlineCache[text] { return cached }
    let parsed = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
    if inlineCache.count > 2000 { inlineCache.removeAll() }
    inlineCache[text] = parsed
    return parsed
}

// MARK: Summary

struct SummaryTab: View {
    @ObservedObject var store: NotesStore
    let page: MeetingPage
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let meta = page.item.meta
        let busy = store.isBusy(page.item.id)
        VStack(alignment: .leading, spacing: 18) {
            if busy { progress }
            if let blocks = page.summary {
                VStack(alignment: .leading, spacing: 10) {
                    caption(meta, busy: busy)
                    BriefingRow(item: page.item, hasSummary: true)
                }
                SummaryView(blocks: blocks, comments: store.comments, seek: page.media == .none ? nil : { time in
                    Motion.animate(Motion.fade) { store.tab = .transcript }
                    store.player.seek(to: time, play: true)
                }, pictures: pictures)
            } else if !busy {
                empty(meta)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var pictures: PictureActions {
        let video: Bool = { if case .video = page.media { return true } else { return false } }()
        return PictureActions(folder: page.item.folder, canPlay: video,
                              play: { [player = store.player] in player.seek(to: $0, play: true) }, open: store.open)
    }

    @ViewBuilder private func empty(_ meta: MeetingMeta) -> some View {
        if meta.confidential ?? false {
            VStack(alignment: .leading, spacing: 10) {
                Text("Not sent for summary")
                    .fontWeight(.semibold)
                Text("This meeting is marked confidential. The transcript stays on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Summarise anyway") { store.summariseConfidential() }
                    .disabled(!page.transcript.hasLines || Settings.summaryProvider == .off)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 640, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .transition(Motion.slide(reduced: Motion.reduced(systemReduceMotion)))
        } else {
            switch page.transcript {
            case .lines:
                if Settings.summaryProvider == .off {
                    state("Summaries are turned off in Settings")
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("No summary yet")
                            .fontWeight(.semibold)
                        Button("Summarise with \(store.model.label)") { store.summarise() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            case .pending:
                state("Transcribing…")
            case .noSpeech:
                state("No speech detected")
            case .missing:
                state(meta.transcriptError.map { "Transcription failed: \($0)" } ?? "No transcript to summarise")
            }
        }
    }

    private func state(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Summarising with \(store.model.label)…").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
    }

    private func caption(_ meta: MeetingMeta, busy: Bool) -> some View {
        let model = meta.summaryModel.map { SummaryModel(rawValue: $0)?.label ?? $0 } ?? "Claude"
        let when = meta.summarizedAt.map { " " + MeetingFormat.when($0, since: meta.startedAt) } ?? ""
        let confidential = meta.confidential ?? false
        let text = Text("Summarised by \(model)\(when)")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
        let menu = Menu("Re-run with…") {
            ForEach(SummaryModel.everywhere, id: \.0) { provider, models in
                Section(provider.name) {
                    ForEach(models, id: \.self) { model in
                        Button(model.label) { store.summarise(with: model) }
                    }
                }
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(busy || confidential || Settings.summaryProvider == .off || !page.transcript.hasLines)
        .help(confidential ? "This meeting is marked confidential" : "Summarise again, replacing this summary")
        // In a narrow page the button goes under the sentence rather than splitting it.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { text; menu }
            VStack(alignment: .leading, spacing: 6) { text; menu }
        }
        .font(.system(size: 12))
    }
}

private struct SummaryView: View {
    let blocks: [SummaryBlock]
    @ObservedObject var comments: CommentsModel
    let seek: ((TimeInterval) -> Void)?
    let pictures: PictureActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                Group {
                    switch block {
                    case .heading(let text):
                        self.text(text, style: .heading, index: index, key: SummaryText.key(block))
                            .accessibilityAddTraits(.isHeader)
                    case .paragraph(let text):
                        self.text(text, style: .summary, index: index, key: SummaryText.key(block))
                    case .bullet(let text, let level):
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary)
                            self.text(text, style: .summary, index: index, key: SummaryText.key(block))
                        }
                        .font(.reading)
                        .padding(.leading, 6 + CGFloat(level) * 16)
                    case .table(let header, let rows):
                        if let items = ActionItem.parse(header: header, rows: rows) {
                            ActionItemsTable(header: header, items: items, seek: seek)
                        } else {
                            TableCard(header: header, rows: rows)
                        }
                    case .picture(let path):
                        // Lined up with the text of the bullet it sits under.
                        if let level = bulletLevel(above: index) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").font(.reading).hidden()
                                SummaryPicture(path: path, actions: pictures)
                            }
                            .padding(.leading, 6 + CGFloat(level) * 16)
                        } else {
                            SummaryPicture(path: path, actions: pictures)
                        }
                    }
                }
                .padding(.top, gap(before: index))
                .id("summary-\(index)")
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func text(_ markdown: String, style: InlineText.Style, index: Int, key: String?) -> some View {
        SelectableText(text: InlineText.attributed(markdown, style: style), style: style,
                       unit: CommentUnit(target: .summary, index: index),
                       marks: comments.highlights(.summary, unit: index), model: comments, widthKey: key)
    }

    private func bulletLevel(above index: Int) -> Int? {
        for block in blocks[..<index].reversed() {
            switch block {
            case .picture: continue
            case .bullet(_, let level): return level
            default: return nil
            }
        }
        return nil
    }

    private func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        switch (blocks[index - 1], blocks[index]) {
        case (_, .heading): return 22
        case (.heading, .table): return 8
        case (.heading, _): return 6
        case (_, .picture): return 8
        case (.picture, _): return 14
        case (.bullet, .bullet): return 2
        default: return 10
        }
    }
}

/// The summary's text, typeset ahead on the page queue at the widths the last page gave each kind of block.
enum SummaryText {
    static func key(_ block: SummaryBlock) -> String? {
        switch block {
        case .heading: return "summary-heading"
        case .paragraph: return "summary-paragraph"
        case .bullet(_, let level): return "summary-bullet-\(level)"
        case .table, .picture: return nil
        }
    }

    static func prepare(_ blocks: [SummaryBlock]) {
        for block in blocks {
            guard let key = key(block), let width = TextPrep.width(for: key) else { continue }
            switch block {
            case .heading(let text): TextPrep.prepare(InlineText.attributed(text, style: .heading), width: width)
            case .paragraph(let text), .bullet(let text, _): TextPrep.prepare(InlineText.attributed(text, style: .summary), width: width)
            case .table, .picture: continue
            }
        }
    }
}

/// A row of the summary's `| งาน | ผู้รับผิดชอบ | กำหนด | เวลา |` table.
struct ActionItem: Equatable {
    let task: String
    let owner: String
    let due: String?
    let time: TimeInterval?

    static func parse(header: [String], rows: [[String]]) -> [ActionItem]? {
        guard header.count == 4, !rows.isEmpty else { return nil }
        // The time column is what tells this table apart from any other four-column one.
        let times = rows.map { MeetingFormat.seconds(fromStamp: $0[3]) }
        guard times.contains(where: { $0 != nil }) else { return nil }
        return zip(rows, times).map { row, time in
            let due = row[2].trimmingCharacters(in: .whitespaces)
            return ActionItem(task: row[0], owner: row[1], due: due.isEmpty || due == "-" ? nil : due, time: time)
        }
    }

    var ownerUnknown: Bool {
        let owner = owner.trimmingCharacters(in: .whitespaces)
        return owner.isEmpty || owner == "-" || owner == "ไม่ระบุ"
    }
}

private struct ActionItemsTable: View {
    let header: [String]
    let items: [ActionItem]
    let seek: ((TimeInterval) -> Void)?

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<3, id: \.self) { column in
                    Text(header[column])
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .cell(vertical: 8)
                }
                Color.clear.frame(width: 1, height: 1)
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Divider().opacity(0.6).gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    Text(inline(item.task))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cell()
                    Text(item.owner)
                        .foregroundStyle(item.ownerUnknown ? .secondary : .primary)
                        .fixedSize()
                        .cell()
                    Text(item.due ?? "–")
                        .foregroundStyle(item.due == nil ? .secondary : .primary)
                        .fixedSize()
                        .cell()
                    time(item.time)
                        .gridColumnAlignment(.trailing)
                        .padding(.horizontal, 12)
                }
            }
        }
        .font(.system(size: 13))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }

    @ViewBuilder private func time(_ time: TimeInterval?) -> some View {
        if let time {
            let clock = MeetingFormat.longClock(time)
            if let seek {
                Button(clock) { seek(time) }
                    .buttonStyle(ClockButtonStyle())
                    .help("Play from \(clock)")
                    .accessibilityLabel("Play from \(clock)")
            } else {
                Text(clock)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

private struct ClockButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12).monospacedDigit())
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.06)))
            .contentShape(Rectangle())
    }
}

private extension View {
    func cell(vertical: CGFloat = 9) -> some View {
        padding(.horizontal, 12).padding(.vertical, vertical)
    }
}

private struct TableCard: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) {
                    Text(inline($0.element))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .cell(vertical: 8)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider().opacity(0.6).gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { Text(inline($0.element)).cell() }
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

// MARK: Transcript

struct TranscriptTab: View {
    @ObservedObject var player: MediaPlayer
    let comments: CommentsModel
    let transcript: MeetingPage.Transcript
    let seek: (TimeInterval) -> Void
    let rename: (_ speaker: String, _ name: String) -> Void

    var body: some View {
        switch transcript {
        case .lines(let lines):
            TranscriptList(player: player, comments: comments, lines: lines, seek: seek) { speaker in
                Ask.text("Rename \(speaker)", value: speaker, button: "Rename") { rename(speaker, $0) }
            }
        case .noSpeech:
            state("No speech detected")
        case .pending:
            state("Transcribing…")
        case .missing:
            state("No transcript")
        }
    }

    private func state(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }
}

private struct TranscriptList: View {
    @ObservedObject var player: MediaPlayer
    @ObservedObject var comments: CommentsModel
    let lines: [TranscriptLine]
    let seek: (TimeInterval) -> Void
    let askName: (String) -> Void
    @State private var hovered: Int?

    var body: some View {
        let started = player.player != nil && (player.isPlaying || player.time > 0)
        let current = started ? lines.last(where: { $0.time <= player.time + 0.25 })?.id : nil
        let speakerWidth = Self.speakerWidth(lines)
        LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(lines) { line in
                TranscriptRow(line: line, speakerWidth: speakerWidth, current: line.id == current, hovered: line.id == hovered,
                              comments: comments, seek: seek, askName: askName)
                    .id("transcript-\(line.id)")
                    .onHover { inside in
                        if inside { hovered = line.id } else if hovered == line.id { hovered = nil }
                    }
                    .onTapGesture { seek(line.time) }
                    .contextMenu {
                        if TranscriptLine.canRename(line.speaker) {
                            Button("Rename Speaker…") { askName(line.speaker) }
                        }
                    }
                    .accessibilityAction { seek(line.time) }
                    .accessibilityActions {
                        if TranscriptLine.canRename(line.speaker) {
                            Button("Rename Speaker") { askName(line.speaker) }
                        }
                    }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        // Row highlights reach past the text column so the text itself lines up with the header.
        .padding(.horizontal, -10)
    }

    /// Wide enough for the longest speaker name, within limits; "Others" sets the usual width.
    private static func speakerWidth(_ lines: [TranscriptLine]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let widest = Set(lines.map(\.speaker)).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(max(ceil(widest) + 2, 60), 140)
    }
}

private struct TranscriptRow: View {
    let line: TranscriptLine
    let speakerWidth: CGFloat
    let current: Bool
    let hovered: Bool
    let comments: CommentsModel
    let seek: (TimeInterval) -> Void
    let askName: (String) -> Void

    var body: some View {
        let clock = MeetingFormat.longClock(line.time)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(clock)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(line.speaker)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: speakerWidth, alignment: .leading)
            SelectableText(
                text: InlineText.attributed(line.text, style: .transcript), style: .transcript,
                unit: CommentUnit(target: .transcript, index: line.id),
                marks: comments.highlights(.transcript, unit: line.id), model: comments,
                onClick: { [time = line.time] in seek(time) },
                menu: { [speaker = line.speaker] in
                    TranscriptLine.canRename(speaker) ? [ActionMenuItem("Rename Speaker…") { askName(speaker) }] : []
                })
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(current ? Color.accentColor.opacity(0.12) : hovered ? Color.primary.opacity(0.04) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays from \(clock)")
        .accessibilityAddTraits(.isButton)
    }
}
