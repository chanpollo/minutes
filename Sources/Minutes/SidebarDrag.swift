import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A meeting or group dragged inside the notes window; never offered to other apps.
    static let minutesSidebarItem = UTType(exportedAs: "com.enta1234.minutes.sidebar-item")
}

/// A drag in the sidebar: a meeting onto a group, or a group to a new place in the list.
final class SidebarDragModel: ObservableObject {
    enum Item: Equatable {
        case meeting(String)
        case group(String)
    }

    enum Target: Hashable {
        case all
        case group(String)
    }

    @Published private(set) var dragging: Item?
    /// The row a meeting is held over.
    @Published private(set) var target: Target?
    /// Where the dragged group would land, as an index into the groups.
    @Published private(set) var insertion: Int?
    private var pendingExit: DispatchWorkItem?

    /// Called when a drag starts. The data is only readable by this process, so Finder, Mail or another app gets nothing.
    func begin(_ item: Item) -> NSItemProvider {
        reset()
        dragging = item
        let data: Data
        switch item {
        case .meeting(let id): data = Data("meeting:\(id)".utf8)
        case .group(let id): data = Data("group:\(id)".utf8)
        }
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.minutesSidebarItem.identifier, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    /// `current`: where the dragged meeting already is; dropping there would do nothing.
    func accepts(_ target: Target, current: Target? = nil) -> Bool {
        switch dragging {
        case .meeting: return target != current
        case .group(let id): return target != .group(id) || insertion != nil
        case nil: return false
        }
    }

    func enter(_ target: Target, groups: [MeetingGroup], current: Target? = nil) {
        pendingExit?.cancel()
        pendingExit = nil
        switch dragging {
        case .meeting:
            self.target = target == current ? nil : target
        case .group(let dragged):
            let shown = displayed(groups)
            switch target {
            case .all:
                insertion = 0
            case .group(let id) where id != dragged:
                if let index = shown.firstIndex(where: { $0.id == id }) { insertion = index }
            case .group:
                // Over its own gap: the gap stays where it is.
                if insertion == nil { insertion = groups.firstIndex { $0.id == dragged } }
            }
        case nil:
            break
        }
    }

    func exit(_ target: Target) {
        switch dragging {
        case .meeting:
            if self.target == target { self.target = nil }
        case .group:
            // Rows shift under the pointer as the gap moves; the next row's enter cancels this.
            let work = DispatchWorkItem { [weak self] in self?.insertion = nil }
            pendingExit?.cancel()
            pendingExit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        case nil:
            break
        }
    }

    @discardableResult
    func perform(_ target: Target, store: NotesStore) -> Bool {
        defer { reset() }
        switch dragging {
        case .meeting(let id):
            let group: String?
            switch target {
            case .all: group = nil
            case .group(let id): group = id
            }
            return store.dropMeeting(id, on: group)
        case .group(let id):
            let index: Int?
            switch target {
            case .all: index = 0
            case .group(let other): index = insertion ?? displayed(store.groups).firstIndex { $0.id == other }
            }
            guard let index else { return false }
            return store.moveGroup(id, to: index)
        case nil:
            return false
        }
    }

    func reset() {
        pendingExit?.cancel()
        pendingExit = nil
        dragging = nil
        target = nil
        insertion = nil
    }

    /// The groups as the list shows them: the dragged one already at its insertion point.
    func displayed(_ groups: [MeetingGroup]) -> [MeetingGroup] {
        guard case .group(let id) = dragging, let insertion, let from = groups.firstIndex(where: { $0.id == id }) else { return groups }
        var shown = groups
        let group = shown.remove(at: from)
        shown.insert(group, at: min(max(insertion, 0), shown.count))
        return shown
    }

    /// The empty place a dragged group would drop into.
    func isGap(_ groupID: String) -> Bool {
        dragging == .group(groupID) && insertion != nil
    }
}

struct SidebarDropDelegate: DropDelegate {
    let target: SidebarDragModel.Target
    let drag: SidebarDragModel
    let store: NotesStore

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.minutesSidebarItem]) && drag.dragging != nil
    }

    func dropEntered(info: DropInfo) {
        drag.enter(target, groups: store.groups, current: current)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: drag.accepts(target, current: current) ? .move : .forbidden)
    }

    /// The dragged meeting's own place.
    private var current: SidebarDragModel.Target? {
        guard case .meeting(let id) = drag.dragging, let item = store.item(id) else { return nil }
        return store.groupID(of: item).map { .group($0) } ?? .all
    }

    func dropExited(info: DropInfo) {
        drag.exit(target)
    }

    func performDrop(info: DropInfo) -> Bool {
        drag.perform(target, store: store)
    }
}

/// The row under the pointer while it is dragged, lifted off the list.
struct LiftedRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 236, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.liftedRow))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .padding(12)
    }
}

private extension Color {
    /// White in light mode; in dark, a shade lighter than the sidebar so the row stands off it.
    static let liftedRow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.21, alpha: 1) : .white
    })
}
