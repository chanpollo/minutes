import Foundation

/// A provider and one of its models: Claude Code, Codex (ChatGPT), Gemini through Antigravity, or a local Ollama model.
struct SummaryModel: Hashable {
    enum Provider: String, CaseIterable {
        case claude, codex, agy, ollama

        var name: String {
            switch self {
            case .claude: "Claude"
            case .codex: "Codex"
            case .agy: "Gemini"
            case .ollama: "Ollama"
            }
        }
    }

    let provider: Provider
    /// The provider's model id; empty for Codex means its own default.
    let name: String

    static let claudeModels = ["sonnet", "opus", "haiku"]

    init(provider: Provider, name: String) {
        self.provider = provider
        self.name = name
    }

    /// Claude models stay bare ("sonnet"), as meta.json and `--model` had them before other providers.
    init?(rawValue: String) {
        if Self.claudeModels.contains(rawValue) {
            self.init(provider: .claude, name: rawValue)
            return
        }
        guard let colon = rawValue.firstIndex(of: ":"), let provider = Provider(rawValue: String(rawValue[..<colon])),
              provider != .claude else { return nil }
        self.init(provider: provider, name: String(rawValue[rawValue.index(after: colon)...]))
    }

    var rawValue: String { provider == .claude ? name : "\(provider.rawValue):\(name)" }

    var label: String {
        switch provider {
        case .claude: "Claude \(name.capitalized)"
        case .codex: name.isEmpty ? "Codex" : CodexEngine.displayName(name)
        case .agy: name.isEmpty ? "Gemini" : AgyEngine.displayName(name)
        case .ollama: name.isEmpty ? "Ollama" : "\(name) (Ollama)"
        }
    }

    private static func key(_ provider: Provider) -> String {
        switch provider {
        case .claude: "summaryModel"
        case .codex: "codexModel"
        case .agy: "agyModel"
        case .ollama: "ollamaModel"
        }
    }

    /// The model for the provider chosen in Settings; choosing one also makes its provider the one in Settings.
    static var current: SummaryModel {
        get { chosen(Settings.summaryProvider.engine ?? .claude) }
        set {
            Settings.summaryProvider = Settings.SummaryProvider(newValue.provider)
            remember(newValue)
        }
    }

    /// Keeps `model` as its provider's choice without changing the provider in Settings.
    static func remember(_ model: SummaryModel) {
        UserDefaults.standard.set(model.name, forKey: key(model.provider))
    }

    /// The model last chosen for `provider`, while it is still on offer.
    static func chosen(_ provider: Provider) -> SummaryModel {
        let choices = choices(provider)
        let saved = UserDefaults.standard.string(forKey: key(provider)).map { SummaryModel(provider: provider, name: $0) }
        if let saved, choices.contains(saved) || provider == .codex || provider == .agy { return saved }
        return choices.first ?? SummaryModel(provider: provider, name: "")
    }

    static func choices(_ provider: Provider) -> [SummaryModel] {
        switch provider {
        case .claude: claudeModels.map { SummaryModel(provider: .claude, name: $0) }
        case .codex: CodexEngine.models().map { SummaryModel(provider: .codex, name: $0) }
        case .agy: AgyEngine.models().map { SummaryModel(provider: .agy, name: $0) }
        case .ollama: OllamaEngine.installed().map { SummaryModel(provider: .ollama, name: $0) }
        }
    }

    /// Every model of every provider found on this Mac, for "Re-run with…".
    static var everywhere: [(Provider, [SummaryModel])] {
        Provider.allCases.filter { unavailable($0) == nil }.map { ($0, choices($0)) }.filter { !$0.1.isEmpty }
    }

    /// Why this provider cannot be used now; nil when it can.
    static func unavailable(_ provider: Provider) -> String? {
        switch provider {
        case .claude:
            return Summarizer.claudePath() == nil ? "Claude Code CLI not found" : nil
        case .codex:
            if CodexEngine.path() == nil { return "Codex CLI not found" }
            return CodexEngine.signedIn() ? nil : "Codex is not signed in. Run: codex login"
        case .agy:
            if AgyEngine.path() == nil { return "Antigravity CLI (agy) not found" }
            return AgyEngine.signedIn() ? nil : "Antigravity is not signed in. Run agy once in Terminal"
        case .ollama:
            if OllamaEngine.path() == nil { return "Ollama not found" }
            return OllamaEngine.installed().isEmpty ? "No Ollama model on this Mac. Pull one with: ollama pull qwen2.5" : nil
        }
    }

    var unavailable: String? { Self.unavailable(provider) }

    /// The CLI's own sign-in; agy has no login command and signs in with Google the first time it runs.
    static func signInCommand(_ provider: Provider) -> [String]? {
        switch provider {
        case .claude: Summarizer.claudePath().map { [$0, "auth", "login"] }
        case .codex: CodexEngine.path().map { [$0, "login"] }
        case .agy: AgyEngine.path().map { [$0] }
        case .ollama: nil
        }
    }

    var timeout: TimeInterval {
        switch provider {
        case .claude: 300
        case .codex, .agy: 600
        // A long transcript takes minutes to read on the Mac's own chip.
        case .ollama: 1200
        }
    }
}

/// Finds a command line tool from a GUI app, which gets no shell PATH.
enum CLITool {
    static func find(_ name: String, customKey: String, extra: [String] = []) -> String? {
        let fm = FileManager.default
        // A path set by hand wins and is not second-guessed, so a wrong one shows up as an error.
        if let custom = UserDefaults.standard.string(forKey: customKey), !custom.isEmpty {
            return fm.isExecutableFile(atPath: custom) ? custom : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let fixed = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] + extra
        if let found = fixed.first(where: fm.isExecutableFile(atPath:)) { return found }

        // nvm's Node versions, newest first.
        let nvm = "\(home)/.nvm/versions/node"
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { numbers($0).lexicographicallyPrecedes(numbers($1)) }
        return versions.reversed().map { "\(nvm)/\($0)/bin/\(name)" }.first(where: fm.isExecutableFile(atPath:))
    }

    private static func numbers(_ name: String) -> [Int] {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
    }

    struct Output {
        let status: Int32
        let output: Data
        let errors: Data

        var errorTail: String {
            let detail = errors.isEmpty ? output : errors
            return String(decoding: detail.suffix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs a tool with `input` on stdin; throws when it is cancelled or runs past `timeout`.
    static func run(_ path: String, arguments: [String], input: String, directory: URL, timeout: TimeInterval,
                    name: String, cancel: Summarizer.ClaudeCancel?) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // An npm-installed tool is a `#!/usr/bin/env node` script; node sits beside it.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: path).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // If the tool exits without reading stdin, the write must fail with EPIPE rather than kill the app with SIGPIPE.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        cancel?.attach(process)

        let errors = Buffer()
        let readers = DispatchGroup()
        DispatchQueue.global().async(group: readers) { errors.data = stderr.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let timedOut = Buffer()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.data = Data([1])
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        readers.wait()

        if cancel?.isCancelled == true { throw CancellationError() }
        if !timedOut.data.isEmpty {
            throw SummaryError(message: "\(name) did not finish within \(Int(timeout / 60)) minutes")
        }
        return Output(status: process.terminationStatus, output: output, errors: errors.data)
    }

    final class Buffer: @unchecked Sendable {
        var data = Data()
    }
}

/// `codex exec` on the user's ChatGPT sign-in, with their config, MCP servers and tools left out.
enum CodexEngine {
    private static let pathKey = "codexPath"
    private static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    static func path() -> String? { CLITool.find("codex", customKey: pathKey) }

    static func signedIn() -> Bool {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["tokens"] is [String: Any] || (json["OPENAI_API_KEY"] as? String)?.isEmpty == false
    }

    private struct Listed { let slug, name: String }

    /// Models Codex lists for the account, best first, from the cache Codex keeps; empty means Codex's own default.
    private static func listed() -> [Listed] {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                (model["slug"] as? String).map { Listed(slug: $0, name: model["display_name"] as? String ?? $0) }
            }
    }

    static func models() -> [String] {
        let slugs = listed().prefix(5).map(\.slug)
        return slugs.isEmpty ? [""] : Array(slugs)
    }

    static func displayName(_ slug: String) -> String {
        listed().first { $0.slug == slug }?.name ?? slug
    }

    /// Features on by default that a summary has no use for; ones this Codex does not know are dropped and retried.
    private static let offFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "memories", "multi_agent", "image_generation", "browser_use",
        "browser_use_external", "computer_use", "in_app_browser", "hooks", "goals", "view_image", "tool_suggest",
        "skill_search", "sleep_tool",
    ]

    static func run(model: String, system: String, input: String, directory: URL, timeout: TimeInterval,
                    cancel: Summarizer.ClaudeCancel?) throws -> String {
        guard let codex = path() else { throw SummaryError(message: "Codex CLI not found") }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("minutes-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let reply = scratch.appendingPathComponent("reply.md")
        // Codex always reads $CODEX_HOME/AGENTS.md, so these instructions say they are the only ones.
        let instructions = """
            A program calls you; there is no one to chat with. Do not run commands or use any tool. These instructions \
            replace any others you were given about language, tone, format or the user (such as AGENTS.md).


            """ + system
        var off = offFeatures
        for _ in 0..<offFeatures.count {
            var arguments = [
                "exec", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--ephemeral",
                "--sandbox", "read-only", "--color", "never", "--cd", directory.path,
                "-c", "web_search=\"disabled\"", "-c", "developer_instructions=\(toml(instructions))",
                "--output-last-message", reply.path,
            ]
            arguments += off.flatMap { ["--disable", $0] }
            if !model.isEmpty { arguments += ["--model", model] }
            arguments.append("Do what your developer instructions say with the text in the stdin block.")
            let result = try CLITool.run(codex, arguments: arguments, input: input, directory: directory, timeout: timeout,
                                         name: "Codex", cancel: cancel)
            if result.status == 0 {
                return (try? String(contentsOf: reply, encoding: .utf8)) ?? String(decoding: result.output, as: UTF8.self)
            }
            let tail = result.errorTail
            if let unknown = tail.range(of: "Unknown feature flag: ") {
                let flag = tail[unknown.upperBound...].prefix { !$0.isWhitespace }
                if let index = off.firstIndex(of: String(flag)) {
                    off.remove(at: index)
                    continue
                }
            }
            throw SummaryError(message: "codex exited with \(result.status): \(tail)")
        }
        throw SummaryError(message: "codex refused its feature flags")
    }

    /// A TOML basic string; JSON's escapes are TOML's once slashes are left alone.
    static func toml(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// `agy -p` (Antigravity) on the user's Google sign-in. It has no system prompt flag and does not read stdin in text
/// mode, so instructions and transcript go together as one stream-json message.
enum AgyEngine {
    private static let pathKey = "agyPath"
    private static let modelsKey = "agyModels"

    static func path() -> String? { CLITool.find("agy", customKey: pathKey) }

    static func signedIn() -> Bool {
        FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json").path)
    }

    /// slug → display name from the last `agy models`, kept so menus never wait on the network.
    private static var cached: [[String]] {
        UserDefaults.standard.array(forKey: modelsKey) as? [[String]] ?? []
    }

    /// One entry per Gemini family at medium effort ("gemini-4-argon-medium"); empty means agy's own default.
    static func models() -> [String] {
        let slugs = cached.map { $0[0] }.filter { $0.hasPrefix("gemini-") && $0.hasSuffix("-medium") }
        return slugs.isEmpty ? [""] : slugs
    }

    static func displayName(_ slug: String) -> String {
        let name = cached.first { $0[0] == slug }.map { $0[1] } ?? slug
        return name.replacingOccurrences(of: " (Medium)", with: "")
    }

    /// Asks agy for the account's models in the background; `done` runs on the main thread when the list changed.
    static func refreshModels(done: @escaping () -> Void) {
        guard let agy = path(), signedIn() else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let result = try? CLITool.run(agy, arguments: ["models"], input: "", directory: Summarizer.workDir,
                                                timeout: 60, name: "agy", cancel: nil), result.status == 0 else { return }
            let rows = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap { line -> [String]? in
                let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && !parts[0].contains(" ") ? parts : nil
            }
            guard !rows.isEmpty else { return }
            DispatchQueue.main.async {
                guard rows != cached else { return }
                UserDefaults.standard.set(rows, forKey: modelsKey)
                done()
            }
        }
    }

    static func run(model: String, system: String, input: String, directory: URL, timeout: TimeInterval,
                    cancel: Summarizer.ClaudeCancel?) throws -> String {
        guard let agy = path() else { throw SummaryError(message: "Antigravity CLI (agy) not found") }
        let prompt = """
            A program calls you; there is no one to chat with. Do not use any tool, file or web search: everything \
            you need is below. Follow these instructions:

            \(system)

            The input:

            \(input)
            """
        let message: [String: Any] = ["event": "user", "message": ["role": "user", "content": prompt]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self) + "\n"
        var arguments = [
            "--input-format", "stream-json", "--output-format", "stream-json", "--disable-slash-commands", "--sandbox",
            "--print-timeout", "\(Int(timeout))s",
        ]
        if !model.isEmpty { arguments += ["--model", model] }
        // -p takes its prompt as a value; with stream-json input it is empty.
        arguments.append("-p=")
        let result = try CLITool.run(agy, arguments: arguments, input: line, directory: directory, timeout: timeout + 30,
                                     name: "Gemini", cancel: cancel)
        let events = String(decoding: result.output, as: UTF8.self).split(separator: "\n").compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
        guard let outcome = events.last(where: { $0["event"] as? String == "result" })?["result"] as? [String: Any] else {
            throw SummaryError(message: "agy exited with \(result.status): \(result.errorTail)")
        }
        guard outcome["status"] as? String == "SUCCESS", let response = outcome["response"] as? String else {
            let detail = outcome["error"] as? String ?? outcome["status"] as? String ?? "no response"
            throw SummaryError(message: "agy: \(detail)")
        }
        return response
    }
}

/// A model pulled into Ollama, run on this Mac: nothing leaves it.
enum OllamaEngine {
    private static let pathKey = "ollamaPath"
    /// The Ollama app's own server, used when it is running; Minutes never starts one there.
    static let appPort = 11434
    /// Where Minutes starts `ollama serve` when none is running (default + 10000).
    static let ownPort = 21434

    static func path() -> String? {
        CLITool.find("ollama", customKey: pathKey, extra: ["/Applications/Ollama.app/Contents/Resources/ollama"])
    }

    private static var modelsFolder: URL {
        ProcessInfo.processInfo.environment["OLLAMA_MODELS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
    }

    /// Models pulled on this Mac, read from Ollama's manifests so no server has to be up: "qwen2.5:7b".
    static func installed() -> [String] {
        let fm = FileManager.default
        let manifests = modelsFolder.appendingPathComponent("manifests")
        guard let walker = fm.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var names: [String] = []
        for case let file as URL in walker where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let parts = file.path.dropFirst(manifests.path.count).split(separator: "/").map(String.init)
            guard parts.count == 4, !parts[3].hasPrefix(".") else { continue }
            let (host, space, repo, tag) = (parts[0], parts[1], parts[2], parts[3])
            let base = host == "registry.ollama.ai" ? (space == "library" ? repo : "\(space)/\(repo)") : "\(host)/\(space)/\(repo)"
            names.append("\(base):\(tag)")
        }
        return names.sorted()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var server: Process?

    /// A running server: the Ollama app's, one Minutes started earlier, or a new one on `ownPort`.
    static func base() throws -> URL {
        for port in [appPort, ownPort] {
            let url = URL(string: "http://127.0.0.1:\(port)")!
            if reachable(url) { return url }
        }
        guard let ollama = path() else { throw SummaryError(message: "Ollama not found") }
        let url = URL(string: "http://127.0.0.1:\(ownPort)")!
        try lock.withLock {
            if server?.isRunning == true { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ollama)
            process.arguments = ["serve"]
            var environment = ProcessInfo.processInfo.environment
            environment["OLLAMA_HOST"] = "127.0.0.1:\(ownPort)"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            server = process
        }
        for _ in 0..<40 {
            if reachable(url) { return url }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw SummaryError(message: "Ollama did not start on port \(ownPort)")
    }

    /// Stops the server Minutes started, when the app quits.
    static func stop() {
        lock.withLock {
            if server?.isRunning == true { server?.terminate() }
            server = nil
        }
    }

    private static func reachable(_ base: URL) -> Bool {
        var request = URLRequest(url: base.appendingPathComponent("api/version"))
        request.timeoutInterval = 1
        return (try? send(request, cancel: nil)) != nil
    }

    static func run(model: String, system: String, input: String, timeout: TimeInterval,
                    cancel: Summarizer.ClaudeCancel?) throws -> String {
        guard !model.isEmpty else { throw SummaryError(message: "No Ollama model chosen") }
        let base = try base()
        let limit = contextLength(base, model: model)
        // Ollama cuts a prompt that does not fit its window without a word, so size the window to the text.
        let needed = (system.unicodeScalars.count + input.unicodeScalars.count) / 2 + 4096
        let window = min(limit, max(8192, (needed + 4095) / 4096 * 4096))
        let body: [String: Any] = [
            "model": model, "stream": false, "keep_alive": "2m",
            "options": ["num_ctx": window, "temperature": 0.2],
            "messages": [["role": "system", "content": system], ["role": "user", "content": input]],
        ]
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout
        let reply = try send(request, cancel: cancel)
        guard let message = reply["message"] as? [String: Any], let content = message["content"] as? String else {
            throw SummaryError(message: "Ollama: \(reply["error"] as? String ?? "no reply")")
        }
        if let read = reply["prompt_eval_count"] as? Int, read >= window - 16 {
            throw SummaryError(message: "The transcript is longer than \(model) can read at once (\(window) tokens)")
        }
        return content.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "", options: .regularExpression)
    }

    /// The model's longest context, capped where the Mac's memory still copes.
    private static func contextLength(_ base: URL, model: String) -> Int {
        var request = URLRequest(url: base.appendingPathComponent("api/show"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        request.timeoutInterval = 30
        let info = (try? send(request, cancel: nil))?["model_info"] as? [String: Any] ?? [:]
        let length = info.first { $0.key.hasSuffix(".context_length") }?.value as? Int ?? 8192
        return min(length, 65536)
    }

    private static func send(_ request: URLRequest, cancel: Summarizer.ClaudeCancel?) throws -> [String: Any] {
        let done = DispatchSemaphore(value: 0)
        let result = CLITool.Buffer()
        let failed = Failure()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                failed.error = error
            } else if let data {
                result.data = data
                if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    failed.error = SummaryError(message: "Ollama: \(json?["error"] as? String ?? "HTTP \(http.statusCode)")")
                }
            }
            done.signal()
        }
        task.resume()
        cancel?.attach { task.cancel() }
        done.wait()
        if cancel?.isCancelled == true { throw CancellationError() }
        if let error = failed.error { throw error }
        guard let json = try JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            throw SummaryError(message: "Ollama sent something that is not JSON")
        }
        return json
    }

    private final class Failure: @unchecked Sendable {
        var error: Error?
    }
}
