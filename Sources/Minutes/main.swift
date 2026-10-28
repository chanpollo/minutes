import AppKit

private func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(code)
}

private func run(_ work: () throws -> URL) -> Never {
    do {
        print(try work().path)
        exit(0)
    } catch {
        fail(error.localizedDescription)
    }
}

// Command line, for meetings already on disk:
//   Minutes --transcribe <meeting folder>
//   Minutes --summarize <meeting folder> [--model sonnet|opus|haiku]
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, command.hasPrefix("-") {
    let usage = "usage: Minutes --transcribe <folder>\n       Minutes --summarize <folder> [--model sonnet|opus|haiku]"
    switch (command, arguments.count) {
    case ("--transcribe", 2):
        let folder = URL(fileURLWithPath: arguments[1])
        let meta = Workspace.readMeta(folder)
        run {
            try Transcriber.transcribe(
                folder: folder, title: meta?.title ?? folder.lastPathComponent, startedAt: meta?.startedAt ?? Date(),
                id: meta?.id)
        }
    case ("--summarize", 2), ("--summarize", 4):
        var model = SummaryModel.current
        if arguments.count == 4 {
            guard arguments[2] == "--model", let picked = SummaryModel(rawValue: arguments[3]) else { fail(usage, code: 2) }
            model = picked
        }
        run { try Summarizer.summarize(folder: URL(fileURLWithPath: arguments[1]), model: model) }
    default:
        fail(usage, code: 2)
    }
}

// A second copy would take over the first one's recording in staging.
if let id = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
