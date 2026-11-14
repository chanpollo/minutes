import AppKit

/// The menu bar at the top of the screen while Minutes is the active app. Edit is what makes copy, paste and undo
/// work in the notes and title fields.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = submenu(of: main, "Minutes")
        app.addItem(withTitle: "About Minutes", action: #selector(VersionsWindowController.showVersions), keyEquivalent: "")
            .target = VersionsWindowController.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(SettingsWindowController.showSettings), keyEquivalent: ",")
            .target = SettingsWindowController.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Minutes", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Minutes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(of: main, "File")
        file.addItem(withTitle: "New Note", action: #selector(NotesWindowController.newNote(_:)), keyEquivalent: "n")
            .target = NotesWindowController.shared
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(of: main, "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Add Comment", action: #selector(CommentTextView.addComment(_:)), keyEquivalent: "K")
        edit.addItem(.separator())
        let find = submenu(of: edit, "Find")
        find.addItem(withTitle: "Find…", action: #selector(NotesWindowController.focusSearch), keyEquivalent: "f")
            .target = NotesWindowController.shared

        let format = submenu(of: main, "Format")
        let item = { (title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) in
            format.addItem(withTitle: title, action: action, keyEquivalent: key).keyEquivalentModifierMask = modifiers
        }
        item("Title", #selector(NotesTextView.formatTitle(_:)), "t", [.command, .shift])
        item("Heading", #selector(NotesTextView.formatHeading(_:)), "h", [.command, .shift])
        item("Subheading", #selector(NotesTextView.formatSubheading(_:)), "j", [.command, .shift])
        item("Body", #selector(NotesTextView.formatBody(_:)), "b", [.command, .shift])
        item("Monospaced", #selector(NotesTextView.formatMonospaced(_:)), "m", [.command, .shift])
        format.addItem(.separator())
        item("Bold", #selector(NotesTextView.formatBold(_:)), "b", .command)
        item("Italic", #selector(NotesTextView.formatItalic(_:)), "i", .command)
        item("Underline", #selector(NotesTextView.formatUnderline(_:)), "u", .command)
        item("Strikethrough", #selector(NotesTextView.formatStrikethrough(_:)), "x", [.command, .shift])
        format.addItem(.separator())
        item("Bulleted List", #selector(NotesTextView.formatBulletedList(_:)), "7", [.command, .shift])
        item("Dashed List", #selector(NotesTextView.formatDashedList(_:)), "8", [.command, .shift])
        item("Numbered List", #selector(NotesTextView.formatNumberedList(_:)), "9", [.command, .shift])
        item("Checklist", #selector(NotesTextView.formatChecklist(_:)), "l", [.command, .shift])
        item("Mark as Checked", #selector(NotesTextView.formatMarkChecked(_:)), "u", [.command, .shift])
        format.addItem(.separator())
        item("Block Quote", #selector(NotesTextView.formatBlockQuote(_:)), "'", .command)
        item("Link…", #selector(NotesTextView.formatLink(_:)), "k", .command)
        format.addItem(.separator())
        item("Insert Picture…", #selector(NotesTextView.formatInsertPicture(_:)), "i", [.command, .shift])

        let view = submenu(of: main, "View")
        view.addItem(withTitle: "Hide Notes", action: #selector(NotesWindowController.toggleNotesColumn(_:)), keyEquivalent: "0")
            .keyEquivalentModifierMask = [.command, .option]
        view.items.forEach { $0.target = NotesWindowController.shared }

        // The selected meeting in the notes window; the sidebar's right-click menu has the same.
        let meeting = submenu(of: main, "Meeting")
        let notes = NotesWindowController.shared
        meeting.addItem(withTitle: "Pin", action: #selector(NotesWindowController.pinMeeting(_:)), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .shift]
        meeting.addItem(withTitle: "Archive", action: #selector(NotesWindowController.archiveMeeting(_:)), keyEquivalent: "a")
            .keyEquivalentModifierMask = [.command, .control]
        meeting.addItem(.separator())
        meeting.addItem(withTitle: "Delete Meeting…", action: #selector(NotesWindowController.deleteMeeting(_:)), keyEquivalent: "\u{8}")
        meeting.items.forEach { $0.target = notes }

        let window = submenu(of: main, "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(of main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
