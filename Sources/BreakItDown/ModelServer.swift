import Foundation
import Observation

/// Starts and stops the local model so nobody has to do it by hand.
///
/// Built-in engine: uses LM Studio's headless CLI (`~/.lmstudio/bin/lms`) to start its
/// local server and load the MLX model folder from Settings. Ollama: runs `ollama serve`
/// as a child process if it isn't already running.
@MainActor
@Observable
final class ModelServer {
    enum Status: Equatable {
        case idle
        case starting(String)
        case ready
        case failed(FriendlyError)
    }

    static let identifier = "break-it-down"

    var status: Status = .idle
    /// The model name to send in chat requests.
    var activeModelName: String = ModelServer.identifier

    private var startedLMServer = false
    private var loadedByUs = false
    private var ollamaProcess: Process?
    private var startTask: Task<Void, Never>?

    var isReady: Bool { status == .ready }

    // MARK: Paths

    static var lmsPath: String? {
        let candidates = [
            NSHomeDirectory() + "/.lmstudio/bin/lms",
            NSHomeDirectory() + "/.cache/lm-studio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ollamaPath: String? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Start / stop

    func start(_ settings: AppSettings) {
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let result: Status
            switch settings.engine {
            case .apple: result = await self.startApple(settings)
            case .lmstudio: result = await self.startLMStudio(settings)
            case .ollama: result = await self.startOllama(settings)
            }
            if !Task.isCancelled { self.status = result }
        }
    }

    func restart(_ settings: AppSettings) {
        Task {
            await stop(settings, unload: true)
            start(settings)
        }
    }

    /// Called when the app quits.
    func stop(_ settings: AppSettings, unload: Bool) async {
        startTask?.cancel()
        if let lms = ModelServer.lmsPath {
            if unload && loadedByUs {
                _ = await Shell.run(lms, ["unload", ModelServer.identifier], timeout: 15)
                loadedByUs = false
            }
            if unload && startedLMServer {
                _ = await Shell.run(lms, ["server", "stop"], timeout: 15)
                startedLMServer = false
            }
        }
        if let p = ollamaProcess, p.isRunning {
            p.terminate()
        }
        ollamaProcess = nil
        status = .idle
    }

    // MARK: Apple engine

    private func startApple(_ s: AppSettings) async -> Status {
        // Nothing to launch; just wait out a first-time model download if one is running.
        for attempt in 0..<120 {
            if Task.isCancelled { return .idle }
            guard let (error, mayResolveSoon) = AppleModel.unavailableReason() else {
                activeModelName = "Apple Intelligence"
                AppleModel.prewarm(instructions: Prompts.defaults.system)
                return .ready
            }
            if !mayResolveSoon || attempt == 119 { return .failed(error) }
            status = .starting("Waiting for Apple's model to finish downloading…")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        return .idle
    }

    // MARK: LM Studio engine

    private func startLMStudio(_ s: AppSettings) async -> Status {
        let modelPath = (s.modelPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelPath, isDirectory: &isDir), isDir.boolValue else {
            return .failed(FriendlyError(
                title: "The model folder wasn't found",
                detail: modelPath,
                fix: "Settings → Model: choose the folder that holds the model (it contains config.json)."))
        }
        guard let lms = ModelServer.lmsPath else {
            return .failed(FriendlyError(
                title: "LM Studio's command-line tool isn't set up",
                detail: "Break It Down uses it to run the model in the background.",
                fix: "Open LM Studio once, then run in Terminal: npx lmstudio install-cli"))
        }
        let base = "http://127.0.0.1:\(s.lmstudioPort)"

        // 1. Server
        status = .starting("Starting the model server…")
        if !(await HTTP.isUp(base + "/v1/models")) {
            var args = ["server", "start"]
            if s.lmstudioPort != 1234 { args += ["--port", String(s.lmstudioPort)] }
            let r = await Shell.run(lms, args, timeout: 60)
            var up = false
            for _ in 0..<40 {
                if Task.isCancelled { return .idle }
                if await HTTP.isUp(base + "/v1/models") { up = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard up else {
                return .failed(FriendlyError(
                    title: "The model server didn't start",
                    detail: r.output.isEmpty ? "lms server start exited with code \(r.status)." : String(r.output.suffix(400)),
                    fix: "Open LM Studio once so it can finish setting up, then click Start model. From Terminal: ~/.lmstudio/bin/lms server start"))
            }
            startedLMServer = true
        }

        // 2. Model
        // LM Studio's own key for a model (e.g. "google/gemma-4-e4b") isn't its folder path
        // ("lmstudio-community/gemma-4-E4B-it-MLX-4bit"). Loading by the folder path fails, so look the key up first.
        let folder = (modelPath as NSString).lastPathComponent
        let key = await catalogKey(base: base, folder: folder) ?? s.lmstudioModelKey
        if let loaded = await loadedModelName(base: base, key: key) {
            activeModelName = loaded
            return .ready
        }
        status = .starting("Loading \(s.modelDisplayName)… (about 10–30 seconds)")
        // --yes: never stop to ask which model to load, which would hang with no terminal attached.
        let r = await Shell.run(lms, ["load", key, "--identifier", ModelServer.identifier, "--yes"], timeout: 240)
        if Task.isCancelled { return .idle }
        if let loaded = await loadedModelName(base: base, key: key) {
            activeModelName = loaded
            loadedByUs = true
            return .ready
        }
        if r.status == 0 {
            // Loaded, but the REST listing didn't confirm it. Trust the CLI.
            activeModelName = ModelServer.identifier
            loadedByUs = true
            return .ready
        }
        return .failed(FriendlyError(
            title: "The model didn't load",
            detail: String(r.output.suffix(500)),
            fix: "In Terminal: ~/.lmstudio/bin/lms load \(key) --identifier \(ModelServer.identifier)"))
    }

    /// Name of an already-loaded copy of our model, if any.
    private func loadedModelName(base: String, key: String) async -> String? {
        guard let json = await HTTP.getJSON(base + "/api/v0/models") as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return nil }
        let folder = (key as NSString).lastPathComponent.lowercased()
        for m in data {
            guard let id = m["id"] as? String, (m["state"] as? String) == "loaded" else { continue }
            let lid = id.lowercased()
            if lid == ModelServer.identifier || lid == key.lowercased() || lid.hasSuffix(folder) {
                return id
            }
        }
        return nil
    }

    /// LM Studio's key for the downloaded model that lives in this folder. Keys are short
    /// ("google/gemma-4-e4b"); folders add a variant suffix ("gemma-4-E4B-it-MLX-4bit"), so match on the longest key
    /// whose last part starts the folder name.
    private func catalogKey(base: String, folder: String) async -> String? {
        guard let json = await HTTP.getJSON(base + "/api/v0/models") as? [String: Any],
              let data = json["data"] as? [[String: Any]] else { return nil }
        let f = folder.lowercased()
        let ids = data.filter { ($0["type"] as? String) != "embeddings" }.compactMap { $0["id"] as? String }
        func name(_ id: String) -> String { (id as NSString).lastPathComponent.lowercased() }
        if let exact = ids.first(where: { name($0) == f }) { return exact }
        return ids.filter { f.hasPrefix(name($0)) }.max { name($0).count < name($1).count }
    }

    // MARK: Ollama engine

    private func startOllama(_ s: AppSettings) async -> Status {
        let base = s.ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        status = .starting("Starting Ollama…")
        if !(await HTTP.isUp(base + "/api/tags")) {
            guard let ollama = ModelServer.ollamaPath else {
                return .failed(FriendlyError(
                    title: "Ollama isn't installed",
                    detail: "Couldn't find the ollama program.",
                    fix: "Run in Terminal: brew install ollama"))
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ollama)
            p.arguments = ["serve"]
            var env = ProcessInfo.processInfo.environment
            if let host = URL(string: base)?.host, let port = URL(string: base)?.port {
                env["OLLAMA_HOST"] = "\(host):\(port)"
            }
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                return .failed(FriendlyError(title: "Ollama didn't start", detail: error.localizedDescription, fix: "Run in Terminal: ollama serve"))
            }
            ollamaProcess = p
            var up = false
            for _ in 0..<30 {
                if await HTTP.isUp(base + "/api/tags") { up = true; break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard up else {
                return .failed(FriendlyError(title: "Ollama didn't start", detail: "It didn't answer at \(base).", fix: "Run in Terminal: ollama serve"))
            }
        }
        let names = await ModelServer.ollamaModels(base: base)
        let want = s.ollamaModel
        let found = names.contains { $0 == want || $0 == want + ":latest" || $0.hasPrefix(want + ":") && !want.contains(":") }
        if !found {
            return .failed(FriendlyError(
                title: "That model isn't installed in Ollama",
                detail: "Ollama is running, but “\(want)” isn't downloaded.",
                fix: "Run in Terminal: ollama pull \(want)"))
        }
        activeModelName = want
        return .ready
    }

    static func ollamaModels(base: String) async -> [String] {
        guard let json = await HTTP.getJSON(base + "/api/tags") as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }
    }

    /// Model folders downloaded in LM Studio (for the Settings picker).
    nonisolated static func lmstudioModelFolders() -> [String] {
        let root = AppSettings.lmstudioModelsDir
        let fm = FileManager.default
        var out: [String] = []
        for publisher in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !publisher.hasPrefix(".") {
            let pdir = root + "/" + publisher
            for model in (try? fm.contentsOfDirectory(atPath: pdir)) ?? [] where !model.hasPrefix(".") {
                let mdir = pdir + "/" + model
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: mdir, isDirectory: &isDir), isDir.boolValue {
                    out.append(mdir)
                }
            }
        }
        return out.sorted()
    }
}

// MARK: - Small helpers

enum HTTP {
    static func getJSON(_ url: String, timeout: TimeInterval = 3) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse, http.statusCode < 400 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0)
    }

    static func isUp(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 2
        guard let result = try? await URLSession.shared.data(for: req),
              let http = result.1 as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }
}

enum Shell {
    struct Result { var status: Int32; var output: String }

    /// Run a program without a shell, capture output to a temp file (no pipe deadlocks), with a timeout.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                var env = ProcessInfo.processInfo.environment
                let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.lmstudio/bin"]
                env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
                env["NO_COLOR"] = "1"
                env["CI"] = "1"
                p.environment = env
                let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("bid-\(UUID().uuidString).log")
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
                let handle = try? FileHandle(forWritingTo: logURL)
                p.standardOutput = handle ?? FileHandle.nullDevice
                p.standardError = handle ?? FileHandle.nullDevice
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, output: error.localizedDescription))
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
                if p.isRunning { p.terminate(); Thread.sleep(forTimeInterval: 0.3) }
                try? handle?.close()
                let out = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: logURL)
                let status: Int32 = p.isRunning ? -2 : p.terminationStatus
                cont.resume(returning: Result(status: status, output: stripANSI(out)))
            }
        }
    }

    static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
