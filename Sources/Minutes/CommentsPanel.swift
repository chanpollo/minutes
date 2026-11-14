import AppKit
import SwiftUI

/// The page's right column: comments in text order, or the meeting's notes, one click apart.
struct SideColumn: View {
    @ObservedObject var comments: CommentsModel
    let notes: NotesDocument
    let tab: NotesStore.Tab

    var body: some View {
        VStack(spacing: 0) {
            SideSwitch(selection: $comments.side, comments: comments.countLabel)
                .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            switch comments.side {
            case .comments:
                CommentsList(model: comments, tab: tab == .transcript ? .transcript : .summary)
            case .notes:
                NotesAside(document: notes)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.notesAside)
    }
}

/// A native segmented control with both segments sharing the column's width, which SwiftUI's Picker does not do.
private struct SideSwitch: NSViewRepresentable {
    @Binding var selection: CommentsModel.Side
    let comments: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: [comments, "Notes"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Side panel")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.label(forSegment: 0) != comments { control.setLabel(comments, forSegment: 0) }
        control.selectedSegment = selection == .comments ? 0 : 1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        // Measuring the control is slow and SwiftUI asks often while a page is first laid out.
        let coordinator = context.coordinator
        if coordinator.measured?.label != comments {
            coordinator.measured = (comments, nsView.intrinsicContentSize)
        }
        let size = coordinator.measured!.size
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    final class Coordinator: NSObject {
        var parent: SideSwitch
        var measured: (label: String, size: CGSize)?
        init(_ parent: SideSwitch) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            parent.selection = control.selectedSegment == 0 ? .comments : .notes
        }
    }
}

private struct CommentsList: View {
    @ObservedObject var model: CommentsModel
    let tab: CommentTarget
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Entry: Identifiable {
        case heading(String)
        case card(MeetingComment, earlier: Bool)
        case resolved(count: Int)
        case composer(CommentsModel.Draft)

        var id: String {
            switch self {
            case .heading(let label): return "heading-" + label
            case .card(let comment, _): return "card-" + comment.id
            case .composer: return "composer"
            case .resolved: return "resolved"
            }
        }
    }

    var body: some View {
        let entries = self.entries
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        switch entry {
                        case .heading(let label):
                            Text(label.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.44)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.top, 12)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        case .card(let comment, let earlier):
                            CommentCard(model: model, comment: comment, earlier: earlier, active: model.active == comment.id)
                                .id(entry.id)
                                .transition(cardTransition)
                        case .resolved(let count):
                            ResolvedToggle(open: $model.showResolved, count: count)
                        case .composer(let draft):
                            ComposerCard(model: model, draft: draft)
                                .id(entry.id)
                                .transition(cardTransition)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(Motion.reduced(reduceMotion) ? nil : Motion.appear, value: entries.map(\.id))
            .onChange(of: model.cardScroll) { _, request in
                guard let request else { return }
                Motion.animate(Motion.reduced(reduceMotion) ? nil : .easeOut(duration: 0.25 * Motion.timeScale)) { proxy.scrollTo(request.id) }
                model.cardScrolled(request)
            }
            // Asked for while the column was hidden or on Notes: the list that comes in scrolls there itself.
            .onAppear {
                guard let request = model.cardScroll else { return }
                DispatchQueue.main.async { proxy.scrollTo(request.id) }
                model.cardScrolled(request)
            }
        }
    }

    private var cardTransition: AnyTransition {
        Motion.slide(reduced: Motion.reduced(reduceMotion))
    }

    /// This tab's comments in text order with the composer among them, the other tab's under a heading, then those
    /// whose text is gone.
    private var entries: [Entry] {
        let draft = model.draft
        var placed: [CommentTarget: [(key: Int, entry: Entry)]] = [:]
        var earlier: [Entry] = []
        let resolved = model.comments.filter { $0.resolvedAt != nil }
        for comment in model.comments where comment.resolvedAt == nil {
            let entry: Entry = draft?.editing == comment.id ? .composer(draft!) : .card(comment, earlier: false)
            if let anchor = model.anchors[comment.id] {
                placed[comment.target, default: []].append((anchor.unit * 1_000_000 + anchor.range.location, entry))
            } else {
                earlier.append(draft?.editing == comment.id ? entry : .card(comment, earlier: true))
            }
        }
        if let draft, draft.editing == nil {
            // Before a card that starts at the same place, as it is the newest.
            placed[draft.target, default: []].append((draft.unit * 1_000_000 + draft.range.location, .composer(draft)))
        }
        let sorted = { (target: CommentTarget) -> [Entry] in
            (placed[target] ?? []).enumerated().sorted {
                ($0.element.key, $0.offset) < ($1.element.key, $1.offset)
            }.map(\.element.entry)
        }
        let other: CommentTarget = tab == .summary ? .transcript : .summary
        var entries = sorted(tab)
        let rest = sorted(other)
        if !rest.isEmpty {
            entries.append(.heading(other == .transcript ? "On the transcript" : "On the summary"))
            entries += rest
        }
        if !earlier.isEmpty {
            entries.append(.heading("Comments on earlier text"))
            entries += earlier
        }
        if !resolved.isEmpty {
            entries.append(.resolved(count: resolved.count))
            if model.showResolved { entries += resolved.map { .card($0, earlier: false) } }
        }
        return entries
    }
}

private struct Avatar: View {
    let author: String

    var body: some View {
        Text(author.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: CommentColors.quoteText))
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color(nsColor: CommentColors.avatar)))
            .accessibilityHidden(true)
    }
}

private struct CardBackground: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: CommentColors.card))
                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
    }
}

private struct QuoteLine: View {
    let quote: String
    var earlier = false
    var resolved = false

    var body: some View {
        let single = quote.components(separatedBy: .newlines).joined(separator: " ")
        Group {
            if resolved {
                Text(single)
                    .foregroundStyle(.secondary)
            } else if earlier {
                Text(single)
                    .strikethrough(color: .secondary)
                    .foregroundStyle(.secondary)
            } else {
                Text(single)
                    .foregroundStyle(Color(nsColor: CommentColors.quoteText))
                    .padding(.horizontal, 2)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: CommentColors.quoteFill)))
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

private struct CommentCard: View {
    @ObservedObject var model: CommentsModel
    let comment: MeetingComment
    let earlier: Bool
    let active: Bool
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var resolved: Bool { comment.resolvedAt != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Avatar(author: comment.author)
                Byline(name: comment.author, when: CommentFormat.when(comment))
                Spacer(minLength: 0)
                // Only on hover, so the name and time keep the width; the context menu has the same commands.
                if hovered || focused {
                    HStack(spacing: 2) {
                        if resolved {
                            ActButton(title: "Reopen") { model.resolve(comment.id, false) }
                        } else {
                            ActButton(title: "Edit") { model.edit(comment.id) }
                        }
                        ActButton(title: "Delete") {
                            Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.fade) { model.delete(comment.id) }
                        }
                    }
                    .focused($focused)
                    .transition(.opacity)
                }
                if !resolved {
                    ResolveButton {
                        Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.fade) { model.resolve(comment.id, true) }
                    }
                }
            }
            Button {
                if earlier { model.active = comment.id } else { model.focus(comment.id) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    QuoteLine(quote: comment.quote, earlier: earlier, resolved: resolved)
                    MessageText(text: comment.text)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(comment.author) on \(comment.quote): \(comment.text)")
            .accessibilityHint(earlier ? "" : "Shows the text")
            ForEach(comment.replies ?? []) { reply in
                ReplyRow(model: model, commentID: comment.id, reply: reply)
            }
            ClaudeStatus(model: model, comment: comment)
            if let at = comment.resolvedAt {
                Text("Resolved by \(comment.resolvedBy ?? "someone") · \(CommentFormat.time(at))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            if active {
                ReplyBox(model: model, commentID: comment.id)
            }
        }
        .modifier(CardBackground(active: active))
        .onHover { hovered = $0 }
        .contextMenu {
            if resolved {
                Button("Reopen") { model.resolve(comment.id, false) }
            } else {
                Button("Resolve") { model.resolve(comment.id, true) }
                Button("Edit") { model.edit(comment.id) }
            }
            Button("Send to \(SummaryModel.current.provider.name)") { model.ask(comment.id) }
                .disabled(model.askUnavailable != nil || model.asking[comment.id] != nil)
            Button("Delete") { Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.fade) { model.delete(comment.id) } }
        }
    }
}

/// "Name · Today 15:05" over a comment or reply.
private struct Byline: View {
    let name: String
    let when: String

    var body: some View {
        HStack(spacing: 0) {
            Text(name)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .truncationMode(.tail)
            Text(" · " + when)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .layoutPriority(1)
    }
}

private struct MessageText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .lineSpacing(3.5)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One reply in a thread: a person's, which they can edit or delete, or Claude's, with Undo while its edit stands.
private struct ReplyRow: View {
    @ObservedObject var model: CommentsModel
    let commentID: String
    let reply: CommentMessage
    @State private var hovered = false

    var body: some View {
        let undo = reply.isClaude && model.undoable.contains(reply.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Avatar(author: reply.author)
                Byline(name: reply.author, when: CommentFormat.time(reply.createdAt)
                       + (reply.undone == true ? " · undone" : reply.editedAt == nil ? "" : " · edited"))
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    if undo {
                        ActButton(title: "Undo") { model.undoRevision(commentID, reply.id) }
                            .help("Put back the text as it was before this change")
                    }
                    if !reply.isClaude, hovered {
                        ActButton(title: "Edit") { model.editingReply = reply.id }
                        ActButton(title: "Delete") { model.deleteReply(commentID, reply.id) }
                    }
                }
            }
            if model.editingReply == reply.id {
                ReplyField(model: model, initial: reply.text, asks: false, done: "Save") { text, _ in
                    model.editReply(commentID, reply.id, text)
                } cancel: {
                    model.editingReply = nil
                }
            } else {
                MessageText(text: reply.text)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) { Divider() }
        .onHover { hovered = $0 }
        .contextMenu {
            if undo { Button("Undo Change") { model.undoRevision(commentID, reply.id) } }
            if !reply.isClaude {
                Button("Edit") { model.editingReply = reply.id }
                Button("Delete") { model.deleteReply(commentID, reply.id) }
            }
        }
    }
}

/// Claude at work on the thread, or why it could not answer.
private struct ClaudeStatus: View {
    @ObservedObject var model: CommentsModel
    let comment: MeetingComment

    var body: some View {
        if model.asking[comment.id] != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(SummaryModel.current.provider.name) is working on it…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ActButton(title: "Stop") { model.stopAsking(comment.id) }
            }
            .padding(.top, 4)
        } else if let error = model.failed[comment.id] {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if model.askUnavailable == nil {
                    ActButton(title: "Try Again") { model.ask(comment.id) }
                }
            }
            .padding(.top, 4)
        }
    }
}

/// "Reply…" under the thread in focus; opens into a field with Reply and Send to Claude.
private struct ReplyBox: View {
    @ObservedObject var model: CommentsModel
    let commentID: String
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        Group {
            if open {
                ReplyField(model: model, initial: "", asks: model.askUnavailable == nil, done: "Reply") { text, ask in
                    model.reply(commentID, text, ask: ask)
                    open = false
                } cancel: {
                    open = false
                }
            } else {
                Button { open = true } label: {
                    Text("Reply…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(hovered ? 2 : 1.4)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityLabel("Reply")
            }
        }
        .padding(.top, 6)
        .onChange(of: commentID) { _, _ in open = false }
    }
}

/// The text field for a reply or an edited reply: ⌘↩ sends it to Claude when `asks`, ⇧⌘↩ or the plain button only posts.
private struct ReplyField: View {
    @ObservedObject var model: CommentsModel
    let initial: String
    let asks: Bool
    let done: String
    let send: (String, Bool) -> Void
    let cancel: () -> Void
    @State private var text = ""
    @State private var focused = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            ComposerField(text: $text, focused: $focused, placeholder: done == "Reply" ? "Reply" : "Edit reply",
                          submit: { submit(asks) }, alternate: asks ? { submit(false) } : nil, cancel: cancel)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(scheme == .dark ? 1 : 1.6), lineWidth: 1))
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                Button("Cancel", action: cancel)
                    .buttonStyle(ComposerButtonStyle(prominent: false))
                Button(done) { submit(false) }
                    .buttonStyle(ComposerButtonStyle(prominent: !asks))
                    .disabled(empty)
                    .help(asks ? "Post without sending to \(SummaryModel.current.provider.name) (⇧⌘↩)" : "")
                if asks {
                    Button("Send to \(SummaryModel.current.provider.name)") { submit(true) }
                        .buttonStyle(ComposerButtonStyle(prominent: true))
                        .disabled(empty)
                        .help("Post, then \(SummaryModel.current.provider.name) answers in the thread and changes the text if asked (⌘↩)")
                }
            }
        }
        .onAppear { text = initial }
    }

    private func submit(_ ask: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(text, ask)
    }
}

/// ✓ at the card's top right, always shown, as on a shared doc's comment thread.
private struct ResolveButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Color(nsColor: CommentColors.hover) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Resolve")
        .accessibilityLabel("Resolve")
    }
}

/// "Resolved · 3" under the open comments; the resolved ones show below it when it is open.
private struct ResolvedToggle: View {
    @Binding var open: Bool
    let count: Int

    var body: some View {
        Button {
            Motion.animate(Motion.appear) { open.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text("RESOLVED · \(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.44)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Hide resolved comments" : "Show \(count) resolved comments")
    }
}

private struct ActButton: View {
    let title: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(hovered ? .primary : .secondary)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Color(nsColor: CommentColors.hover) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ComposerCard: View {
    @ObservedObject var model: CommentsModel
    let draft: CommentsModel.Draft
    @State private var text = ""
    @State private var focused = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            if let id = draft.editing, let comment = model.comments.first(where: { $0.id == id }) {
                HStack(spacing: 8) {
                    Avatar(author: comment.author)
                    Text(CommentFormat.when(comment))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            QuoteLine(quote: draft.quote)
            ComposerField(text: $text, focused: $focused, submit: asks ? ask : post, alternate: asks ? post : nil, cancel: model.cancel)
                .onChange(of: text) { _, value in model.typed = value }
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(scheme == .dark ? 1 : 1.6), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.accentColor.opacity(focused ? (scheme == .dark ? 0.18 : 0.12) : 0), lineWidth: 6))
            HStack(spacing: 8) {
                Text("⌘↩")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                Button("Cancel", action: model.cancel)
                    .buttonStyle(ComposerButtonStyle(prominent: false))
                Button(draft.editing == nil ? "Comment" : "Save", action: post)
                    .buttonStyle(ComposerButtonStyle(prominent: !asks))
                    .disabled(empty)
                    .help(asks ? "Post without sending to \(SummaryModel.current.provider.name) (⇧⌘↩)" : "")
                if asks {
                    Button("Send to \(SummaryModel.current.provider.name)", action: ask)
                        .buttonStyle(ComposerButtonStyle(prominent: true))
                        .disabled(empty)
                        .help("Post, then \(SummaryModel.current.provider.name) answers in the thread and changes the text if asked (⌘↩)")
                }
            }
        }
        .modifier(CardBackground(active: true))
        .onAppear { text = model.typed }
    }

    /// A new comment goes to Claude with ⌘↩ while Claude can take it.
    private var asks: Bool { draft.editing == nil && model.askUnavailable == nil }

    private func post() { send(ask: false) }

    private func ask() { send(ask: true) }

    private func send(ask: Bool) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Motion.animate(Motion.reduced(reduceMotion) ? nil : Motion.appear) { model.post(text, ask: ask) }
    }
}

private struct ComposerButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, prominent ? 12 : 10)
            .frame(height: 26)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: .controlColor))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor).opacity(1.6)))
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

enum CommentFormat {
    /// `Today 15:05`, `Yesterday 09:40`, `27 Oct 15:02`, then ` · edited`.
    static func when(_ comment: MeetingComment, now: Date = Date(), calendar: Calendar = .current) -> String {
        time(comment.createdAt, now: now, calendar: calendar) + (comment.editedAt == nil ? "" : " · edited")
    }

    static func time(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            day = dayFormatter.string(from: date)
        }
        return "\(day) \(MeetingFormat.time(date))"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "d MMM"
        return f
    }()
}

/// Scrolls the page to the text of the comment whose card was clicked.
struct CommentTextScroller: ViewModifier {
    @ObservedObject var model: CommentsModel
    let proxy: ScrollViewProxy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.onChange(of: model.textScroll) { _, request in
            guard let request else { return }
            // The other tab's text is laid out first when the card switched tabs.
            DispatchQueue.main.async {
                Motion.animate(Motion.reduced(reduceMotion) ? nil : .easeOut(duration: 0.25 * Motion.timeScale)) { proxy.scrollTo(request.id) }
            }
        }
    }
}
