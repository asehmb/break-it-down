import Foundation
import AppKit

enum Engine: String, Codable, CaseIterable, Identifiable {
    case apple
    case lmstudio
    case ollama
    var id: String { rawValue }
    var label: String {
        switch self {
        case .apple: return "Apple Intelligence (on-device)"
        case .lmstudio: return "LM Studio (MLX)"
        case .ollama: return "Ollama"
        }
    }
}

enum Theme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

struct AppSettings: Codable, Equatable {
    var engine: Engine = .apple
    var modelPath: String = NSHomeDirectory() + "/.lmstudio/models/lmstudio-community/gemma-4-E4B-it-MLX-4bit"
    var lmstudioPort: Int = 1234
    var ollamaURL: String = "http://localhost:11434"
    var ollamaModel: String = "gemma4:e4b"
    var temperature: Double = 0.3
    var autoStart: Bool = true
    var unloadOnQuit: Bool = true
    var theme: Theme = .system
    var timerOnByDefault: Bool = false
    /// Bumped when a default changes in a way saved settings should pick up.
    var settingsVersion: Int = AppSettings.currentVersion

    static let currentVersion = 2

    init() {}

    enum CodingKeys: String, CodingKey {
        case engine, modelPath, lmstudioPort, ollamaURL, ollamaModel, temperature, autoStart, unloadOnQuit, theme, timerOnByDefault, settingsVersion
    }

    static let lmstudioModelsDir = NSHomeDirectory() + "/.lmstudio/models"

    /// LM Studio identifies a model by its folder path relative to the models dir.
    var lmstudioModelKey: String {
        let dir = AppSettings.lmstudioModelsDir + "/"
        let p = (modelPath as NSString).expandingTildeInPath
        if p.hasPrefix(dir) { return String(p.dropFirst(dir.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        return (p as NSString).lastPathComponent
    }

    var modelDisplayName: String {
        switch engine {
        case .apple: return "Apple Intelligence"
        case .lmstudio: return (modelPath as NSString).lastPathComponent
        case .ollama: return ollamaModel
        }
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(Engine.self, forKey: .engine) { engine = v }
        if let v = try? c.decode(String.self, forKey: .modelPath) { modelPath = v }
        if let v = try? c.decode(Int.self, forKey: .lmstudioPort) { lmstudioPort = v }
        if let v = try? c.decode(String.self, forKey: .ollamaURL) { ollamaURL = v }
        if let v = try? c.decode(String.self, forKey: .ollamaModel) { ollamaModel = v }
        if let v = try? c.decode(Double.self, forKey: .temperature) { temperature = v }
        if let v = try? c.decode(Bool.self, forKey: .autoStart) { autoStart = v }
        if let v = try? c.decode(Bool.self, forKey: .unloadOnQuit) { unloadOnQuit = v }
        if let v = try? c.decode(Theme.self, forKey: .theme) { theme = v }
        if let v = try? c.decode(Bool.self, forKey: .timerOnByDefault) { timerOnByDefault = v }
        // Version 2 made Apple's on-device model the default engine. Older saves were
        // on LM Studio only because nothing else existed, so move them over once.
        let savedVersion = (try? c.decode(Int.self, forKey: .settingsVersion)) ?? 1
        if savedVersion < 2 { engine = .apple }
        settingsVersion = AppSettings.currentVersion
    }
}

/// The model instructions. Saved to prompts.json so they can be edited (in Settings → Prompt, or in any text editor).
struct Prompts: Codable, Equatable {
    var system: String
    var breakdown: String
    var further: String

    static let defaults = Prompts(
        system: """
        You help someone who gets overwhelmed by big tasks and has trouble starting. \
        You break a task into small, concrete physical actions.

        Rules:
        - Break the task into 4 to 10 steps, in the order the person would actually do them.
        - The FIRST step must be tiny and take under 5 minutes, like opening the file, gathering the materials, or writing one sentence. Its minutes must be 5 or less.
        - Every step title starts with a verb and says exactly what to do, in under 12 words.
        - Never use vague steps like "research", "plan", "prepare" or "work on". Say what to physically do.
        - Only give a step substeps when it genuinely has several parts or would take more than about 15 minutes. Otherwise use an empty substeps list.
        - No step longer than 25 minutes. No substep longer than 15 minutes.
        - Use any context the person gives. Do not invent facts about their situation.
        - Reply with JSON only, in this shape: {"steps":[{"title":"...","minutes":5,"substeps":[{"title":"...","minutes":3}]}]}
        """,
        breakdown: """
        Task: {task}
        Context: {context}
        """,
        further: """
        The overall task is: {parent}
        Break down just this one step into 2 to 6 smaller substeps, in order: {step}
        Context: {context}
        Each substep takes 1 to 15 minutes. Return them as the "steps" list, each with an empty substeps list.
        """
    )

    func breakdownMessage(task: String, context: String) -> String {
        breakdown
            .replacingOccurrences(of: "{task}", with: task)
            .replacingOccurrences(of: "{context}", with: context.isEmpty ? "none given" : context)
    }

    func furtherMessage(step: String, parent: String, context: String) -> String {
        further
            .replacingOccurrences(of: "{step}", with: step)
            .replacingOccurrences(of: "{parent}", with: parent)
            .replacingOccurrences(of: "{context}", with: context.isEmpty ? "none given" : context)
    }
}
