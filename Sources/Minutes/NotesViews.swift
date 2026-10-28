import AppKit
import AVKit
import SwiftUI

struct NotesRootView: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        if store.meetings.isEmpty {
            ContentUnavailableView {
                Label("No meetings yet", systemImage: "tray")
            } description: {
                Text(Workspace.root.path).textSelection(.enabled)
            }
        } else {
            NavigationSplitView {
                MeetingList(store: store)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                if let page = store.page {
                    MeetingPageView(store: store, page: page).id(page.item.id)
                } else {
                    ContentUnavailableView("No meeting selected", systemImage: "doc.text")
                }
            }
        }
    }
}

// MARK: Sidebar

private struct MeetingList: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        let groups = MeetingFormat.groups(store.meetings.filter(store.matches))
        VStack(spacing: 0) {
            TextField("Search", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if groups.isEmpty {
                ContentUnavailableView.search(text: store.query)
            } else {
                List(selection: Binding(get: { store.selectedID }, set: { store.select($0) })) {
                    ForEach(groups, id: \.day) { group in
                        Section(group.label) {
                            ForEach(group.items) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.meta.title).bold().lineLimit(1)
                                    Text(MeetingFormat.rowLine(item.meta))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.vertical, 2)
                                .tag(item.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }
}

// MARK: Page

private struct MeetingPageView: View {
    @ObservedObject var store: NotesStore
    let page: MeetingPage

    var body: some View {
        // One tree for both widths; only the notes move, so the title field is never rebuilt mid-edit.
        GeometryReader { geometry in
            let wide = geometry.size.width >= 720
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        content
                        if !wide {
                            Divider()
                            NotesEditor(store: store).frame(height: 240)
                        }
                    }
                    .padding(24)
                }
                if wide {
                    Divider()
                    NotesEditor(store: store).frame(width: 260)
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Transcriber holds the folder path while it runs; a rename would move the folder away from it.
            TitleField(title: page.item.meta.title) { store.rename(page.item.id, to: $0) }
                .disabled(page.transcript.isPending)
                .help(page.transcript.isPending ? "The title can be changed once the transcript is ready" : "")
            HStack {
                Text(MeetingFormat.metaLine(page.item.meta)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([page.item.folder]) }
            }
            PlayerSection(player: store.player, media: page.media)
            Picker("", selection: $store.tab) {
                ForEach(NotesStore.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch store.tab {
            case .summary: SummaryTab(store: store, page: page)
            case .transcript: TranscriptTab(transcript: page.transcript) { store.player.seek(to: $0, play: true) }
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TitleField: View {
    let title: String
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Untitled", text: $draft)
            .textFieldStyle(.plain)
            .font(.system(size: 26, weight: .bold))
            .focused($focused)
            .onAppear { draft = title }
            .onChange(of: title) { _, new in if !focused { draft = new } }
            .onChange(of: focused) { _, isFocused in if !isFocused { save() } }
            .onSubmit(save)
            // Switching meetings removes the field before it reports losing focus.
            .onDisappear(perform: save)
            .onExitCommand {
                draft = title
                focused = false
            }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != title else {
            draft = title
            return
        }
        if !commit(trimmed) { draft = title }
    }
}

// MARK: Player

private struct PlayerSection: View {
    @ObservedObject var player: MediaPlayer
    let media: MediaPlayer.Source

    var body: some View {
        switch media {
        case .none:
            EmptyView()
        case .video:
            VideoView(player: player.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 720, maxHeight: 405)
        case .audio:
            HStack(spacing: 10) {
                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .buttonStyle(.borderless)
                .disabled(player.player == nil)
                Text(MeetingFormat.clock(player.time)).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }), in: 0...max(player.duration, 1))
                    .controlSize(.small)
                    .disabled(player.player == nil)
                Text(MeetingFormat.clock(player.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 720)
        }
    }
}

private struct VideoView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: Summary

private struct SummaryTab: View {
    @ObservedObject var store: NotesStore
    let page: MeetingPage

    var body: some View {
        if let blocks = page.summary {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(summarisedBy).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    SummariseButton(store: store, title: "Summarise again")
                }
                SummaryView(blocks: blocks)
            }
        } else {
            VStack(spacing: 12) {
                Text("No summary yet").font(.title3).foregroundStyle(.secondary)
                SummariseButton(store: store, title: "Summarise")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var summarisedBy: String {
        guard let raw = page.item.meta.summaryModel else { return "Summarised by Claude" }
        return "Summarised by Claude \(SummaryModel(rawValue: raw)?.label ?? raw)"
    }
}

private struct SummariseButton: View {
    @ObservedObject var store: NotesStore
    let title: String

    var body: some View {
        let busy = store.selectedID.map(store.busy.contains) ?? false
        HStack(spacing: 8) {
            if busy {
                ProgressView().controlSize(.small)
                Text("Summarising…").foregroundStyle(.secondary)
            }
            Menu {
                ForEach(SummaryModel.allCases, id: \.self) { model in
                    Toggle(model.label, isOn: Binding(get: { store.model == model }, set: { _ in store.summarise(with: model) }))
                }
            } label: {
                Text("\(title) with \(store.model.label)")
            } primaryAction: {
                store.summarise()
            }
            .fixedSize()
            .disabled(busy)
        }
    }
}

private struct SummaryView: View {
    let blocks: [SummaryBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text)).font(.title3.bold()).padding(.top, 8)
                case .paragraph(let text):
                    Text(inline(text))
                case .bullet(let text, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(text))
                    }
                    .padding(.leading, CGFloat(level) * 16)
                case .table(let header, let rows):
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach(Array(header.enumerated()), id: \.offset) { Text(inline($0.element)).bold() }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { Text(inline($0.element)) }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

// MARK: Transcript

private struct TranscriptTab: View {
    let transcript: MeetingPage.Transcript
    let seek: (TimeInterval) -> Void

    var body: some View {
        switch transcript {
        case .lines(let lines):
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(MeetingFormat.clock(line.time))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.speaker).fontWeight(.semibold)
                            Text(line.text).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { seek(line.time) }
                }
            }
        case .noSpeech:
            state("No speech detected")
        case .pending:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        case .missing:
            state("No transcript")
        }
    }

    private func state(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
    }
}

// MARK: Notes

private struct NotesEditor: View {
    @ObservedObject var store: NotesStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: Binding(get: { store.notes }, set: store.editNotes))
                .font(.body)
        }
        .padding(16)
    }
}
