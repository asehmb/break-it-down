import SwiftUI
import AppKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelSettingsView()
                .tabItem { Label("Model", systemImage: "cpu") }
            PromptSettingsView()
                .tabItem { Label("Prompt", systemImage: "text.quote") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 600, height: 520)
    }
}

struct ModelSettingsView: View {
    @Environment(Store.self) private var store
    @Environment(ModelServer.self) private var server
    @State private var folders: [String] = []
    @State private var ollamaModels: [String] = []
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Picker("Engine", selection: $store.settings.engine) {
                    ForEach(Engine.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Start the model when the app opens", isOn: $store.settings.autoStart)
                Toggle("Unload the model when the app quits", isOn: $store.settings.unloadOnQuit)
            }

            if store.settings.engine == .apple {
                Section("Model") {
                    Text("Uses the model built into macOS 26 with Apple Intelligence. It runs on this Mac, needs no setup, and nothing leaves your machine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let (reason, _) = AppleModel.unavailableReason() {
                        Label(reason.title, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        if let fix = reason.fix {
                            Text(fix).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if store.settings.engine == .lmstudio {
                Section("Model") {
                    Picker("Installed models", selection: $store.settings.modelPath) {
                        ForEach(pickerFolders, id: \.self) { path in
                            Text((path as NSString).lastPathComponent).tag(path)
                        }
                    }
                    HStack {
                        TextField("Model folder", text: $store.settings.modelPath)
                        Button("Choose…", action: chooseFolder)
                    }
                    TextField("Server port", value: $store.settings.lmstudioPort, format: .number.grouping(.never))
                    Text("Runs with LM Studio's headless engine (\(ModelServer.lmsPath ?? "lms not found")). You don't need to open LM Studio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Ollama") {
                    TextField("Ollama URL", text: $store.settings.ollamaURL)
                    HStack {
                        TextField("Model name", text: $store.settings.ollamaModel)
                        if !ollamaModels.isEmpty {
                            Picker("", selection: $store.settings.ollamaModel) {
                                ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                                if !ollamaModels.contains(store.settings.ollamaModel) {
                                    Text(store.settings.ollamaModel).tag(store.settings.ollamaModel)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                    Button("Refresh installed models") { Task { await loadOllama() } }
                }
            }

            Section("Behavior") {
                HStack {
                    Slider(value: $store.settings.temperature, in: 0...1, step: 0.05) {
                        Text("Temperature")
                    }
                    Text(String(format: "%.2f", store.settings.temperature))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text("Low (about 0.3) keeps steps focused and predictable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                HStack {
                    statusText
                    Spacer()
                    Button("Restart model") { server.restart(store.settings) }
                    Button(testing ? "Testing…" : "Test connection") { Task { await test() } }
                        .disabled(testing)
                }
                if let testResult {
                    Text(testResult)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Engine or model changes take effect after Restart model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            folders = ModelServer.lmstudioModelFolders()
            Task { await loadOllama() }
        }
    }

    private var pickerFolders: [String] {
        folders.contains(store.settings.modelPath) ? folders : [store.settings.modelPath] + folders
    }

    @ViewBuilder
    private var statusText: some View {
        switch server.status {
        case .ready: Label("Ready: \(server.activeModelName)", systemImage: "checkmark.circle").foregroundStyle(Palette.accent)
        case .starting(let m): Label(m, systemImage: "hourglass")
        case .idle: Label("Stopped", systemImage: "stop.circle")
        case .failed(let e): Label(e.title, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: AppSettings.lmstudioModelsDir)
        if panel.runModal() == .OK, let url = panel.url {
            store.settings.modelPath = url.path
        }
    }

    private func loadOllama() async {
        let base = store.settings.ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        ollamaModels = await ModelServer.ollamaModels(base: base)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        if !server.isReady {
            if case .failed(let e) = server.status {
                testResult = "Not connected. \(e.title). Fix: \(e.fix ?? "")"
            } else {
                testResult = "The model isn't ready yet (\(statusString)). Press Restart model."
            }
            return
        }
        let start = Date()
        do {
            let reply = try await LLM.chat(system: "You are a test. Reply with one word.", user: "Say OK.",
                                           settings: store.settings, modelName: server.activeModelName)
            let secs = Date().timeIntervalSince(start)
            testResult = String(format: "Connected. %@ replied in %.1f s: “%@”", server.activeModelName, secs,
                                String(reply.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines))
        } catch let e as FriendlyError {
            testResult = "\(e.title). \(e.fix.map { "Fix: " + $0 } ?? "")"
        } catch {
            testResult = error.localizedDescription
        }
    }

    private var statusString: String {
        switch server.status {
        case .ready: return "ready"
        case .starting(let m): return m
        case .idle: return "stopped"
        case .failed(let e): return e.title
        }
    }
}

struct PromptSettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 10) {
            Text("These are the model's instructions. Edits save automatically to prompts.json.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Rules (system prompt)").font(.headline)
            TextEditor(text: $store.prompts.system)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 170)
                .border(Color.secondary.opacity(0.25))
            Text("Break it down message. Uses {task} and {context}").font(.headline)
            TextEditor(text: $store.prompts.breakdown)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 44)
                .border(Color.secondary.opacity(0.25))
            Text("Break this step down further. Uses {step}, {parent}, {context}").font(.headline)
            TextEditor(text: $store.prompts.further)
                .font(.system(.callout, design: .monospaced))
                .frame(height: 70)
                .border(Color.secondary.opacity(0.25))
            HStack {
                Button("Reset to defaults") { store.prompts = .defaults }
                Button("Show prompts.json in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Store.promptsURL])
                }
            }
        }
        .padding(20)
    }
}

struct GeneralSettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $store.settings.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Focus mode") {
                Toggle("Turn the timer on by default", isOn: $store.settings.timerOnByDefault)
            }
            Section("Your data") {
                Text(Store.dataURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                HStack {
                    Button("Export…") { DataTransfer.exportData(store) }
                    Button("Import…") { DataTransfer.importData(store) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Store.dataURL])
                    }
                }
                if let err = store.saveError {
                    Text(err).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}
