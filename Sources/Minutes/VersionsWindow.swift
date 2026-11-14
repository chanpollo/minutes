import AppKit
import SwiftUI

/// About Minutes: the running version and build, and what each build brought, from the CHANGELOG.md inside the app.
/// Opened from the Minutes menu, the menu bar menu, the Dock menu and the line at the foot of Settings.
final class VersionsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = VersionsWindowController()
    static let size = NSSize(width: 520, height: 620)
    static let minSize = NSSize(width: 520, height: 420)
    private static let titleItem = NSToolbarItem.Identifier("title")

    private var window: NSWindow?

    @objc func showVersions() {
        show()
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = VersionsWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        configure(window, version: .current, releases: Changelog.load())
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Versions")
        return window
    }

    /// The title sits in a compact unified toolbar, the same as the notes window's header; on macOS 26 it measures
    /// 40 pt, 2 pt more than the board draws, and no toolbar style gives 38.
    func configure(_ window: NSWindow, version: AppVersion, releases: [Changelog.Release]) {
        window.title = "About Minutes"
        window.titleVisibility = .hidden
        let toolbar = NSToolbar(identifier: "Versions")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.titleItem]
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        let hosting = NSHostingController(rootView: VersionsView(version: version, releases: releases))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.contentMinSize = Self.minSize
        window.setContentSize(Self.size)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.titleItem] }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.titleItem] }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let label = NSTextField(labelWithString: "About Minutes")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        item.view = label
        return item
    }
}

/// Esc closes it; ⌘W closes it through File › Close Window.
final class VersionsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }
}

struct VersionsView: View {
    let version: AppVersion
    let releases: [Changelog.Release]
    @State private var copied = false
    @State private var copies = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Minutes").font(.system(size: 20, weight: .bold))
                    (Text("Version \(version.version) ") + Text("(build \(version.build))").foregroundStyle(.secondary))
                        .font(.system(size: 14))
                    Text(built).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(installed).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 18, trailing: 24))
            // Top right beside the name, so the lines under it keep the full width.
            .overlay(alignment: .topTrailing) {
                Button(action: copy) {
                    ZStack {
                        Text("Copied").hidden()
                        Text(copied ? "Copied" : "Copy")
                    }
                    .foregroundStyle(copied ? .secondary : .primary)
                }
                .controlSize(.small)
                .help("Copy the version line for a bug report")
                .padding(.top, 22)
                .padding(.trailing, 24)
            }
            Text("What changed")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(releases.indices, id: \.self) { index in
                        ReleaseRow(release: releases[index], running: releases[index].build == version.build)
                        Rectangle().fill(Color.versionsRule).frame(height: 1)
                    }
                    if releases.isEmpty {
                        Text("No changelog in this build.")
                            .foregroundStyle(.secondary)
                            .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
                    }
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.notesPage)
    }

    private var built: String {
        var text = "Built " + (version.builtAt.map(AppVersion.dateTime) ?? "—")
        if let commit = version.commitLabel { text += " · " + commit }
        if version.uncommitted { text += ", uncommitted changes" }
        return text
    }

    private var installed: String {
        "Installed " + (version.installedAt.map(AppVersion.dateTime) ?? "—")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version.report, forType: .string)
        copies += 1
        let count = copies
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copies == count { copied = false }
        }
    }
}

private struct ReleaseRow: View {
    let release: Changelog.Release
    let running: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                heading
                if let date = release.dateText {
                    Text(date).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if running {
                    Text("running")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.versionsTagText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.versionsTag))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(release.items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").frame(width: 12, alignment: .trailing)
                        Text(release.items[index]).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heading: Text {
        let version = Text(release.version).fontWeight(.semibold)
        guard let build = release.build else { return version }
        return version + Text(" (build \(build))").foregroundStyle(.secondary)
    }
}

private extension Color {
    /// The notes chip grey for the rule between releases; the "running" tag is a step darker, as on the board.
    static let versionsRule = Color(nsColor: NotesLook.chip)
    static let versionsTag = Color(nsColor: NotesLook.tag)
    static let versionsTagText = Color(nsColor: NotesLook.text2)
}
