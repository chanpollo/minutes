import AppKit

// Minutes --transcribe <meeting folder>: re-run transcription on an existing recording.
let arguments = CommandLine.arguments
if arguments.count == 3, arguments[1] == "--transcribe" {
    let folder = URL(fileURLWithPath: arguments[2])
    do {
        print(try Transcriber.transcribe(folder: folder, title: folder.lastPathComponent, startedAt: Date()).path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
