import AppKit

private func fail(_ message: String, code: Int32 = 1) -> Never {
    OllamaEngine.stop()
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

private func run(_ work: () throws -> URL) -> Never {
    do {
        print(try work().path)
        OllamaEngine.stop()
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

// Command line, for meetings already on disk:
//   Minutes --transcribe <meeting folder>
//   Minutes --summarize <meeting folder> [--model sonnet|opus|haiku|codex:<model>|agy:<model>|ollama:<model>]
//   Minutes --calendar-now [bundle ID]
let arguments = Array(CommandLine.arguments.dropFirst())
let usage = """
    usage: Minutes --transcribe <folder>
           Minutes --summarize <folder> [--model sonnet|opus|haiku|codex:<model>|agy:<model>|ollama:<model>]
           Minutes --calendar-now [bundle ID]
    """
if let command = arguments.first, command.hasPrefix("-") {
    if ["--transcribe", "--summarize"].contains(command), arguments.count >= 2 {
        let folder = URL(fileURLWithPath: arguments[1])
        if let meta = Workspace.readMeta(folder), Workspace.isNote(folder, meta: meta) {
            fail("This folder is a note; nothing to transcribe.")
        }
    }
    switch (command, arguments.count) {
    case ("--transcribe", 2):
        let folder = URL(fileURLWithPath: arguments[1])
        let meta = Workspace.readMeta(folder)
        // No id: the folder given is the one written to, even when a workspace meeting has the same id.
        run {
            try Transcriber.transcribe(
                folder: folder, title: meta?.title ?? folder.lastPathComponent, startedAt: meta?.startedAt ?? Date())
        }
    case ("--summarize", 2), ("--summarize", 4):
        var model = SummaryModel.current
        if arguments.count == 4 {
            guard arguments[2] == "--model", let picked = SummaryModel(rawValue: arguments[3]) else { fail(usage, code: 2) }
            model = picked
        }
        run { try Summarizer.summarize(folder: URL(fileURLWithPath: arguments[1]), model: model, followRenames: false) }
    case ("--calendar-now", 1), ("--calendar-now", 2):
        // Asking needs the usage string, which only the app bundle's Info.plist has.
        if CalendarTitle.status == .notDetermined,
           Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil {
            let answered = DispatchSemaphore(value: 0)
            CalendarTitle.requestAccess { _ in answered.signal() }
            answered.wait()
        }
        switch CalendarTitle.status {
        case .fullAccess: break
        case .notDetermined: FileHandle.standardError.write(Data("calendar access not asked yet\n".utf8))
        case .writeOnly: FileHandle.standardError.write(Data("calendar access is add-only\n".utf8))
        default: FileHandle.standardError.write(Data("calendar access denied\n".utf8))
        }
        if let event = CalendarTitle.current(appBundleID: arguments.count == 2 ? arguments[1] : nil) {
            print(event.title)
            if !event.attendees.isEmpty { print("Invited: \(event.attendees.joined(separator: ", "))") }
        } else {
            print("none")
        }
        exit(0)
    default:
        fail(usage, code: 2)
    }
}

// A second copy would take over the first one's recording in staging. A bare binary outside the .app has no bundle
// identifier to check against, so it only runs the commands above.
guard let id = Bundle.main.bundleIdentifier else {
    fail("Run Minutes.app for the menu bar app; this binary only takes the commands below.\n\(usage)", code: 2)
}
if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = MainMenu.make()
app.run()
