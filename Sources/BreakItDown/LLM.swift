import Foundation

struct DraftStep: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var minutes: Int?
    var substeps: [DraftStep] = []

    /// Convert to a real step, dropping nesting beyond `extraLevels`.
    func toStep(extraLevels: Int) -> Step {
        Step(title: title,
             minutes: minutes,
             children: extraLevels > 0 ? substeps.map { $0.toStep(extraLevels: extraLevels - 1) } : [])
    }
}

/// A plain-language error with the exact fix.
struct FriendlyError: Error, Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    var fix: String? = nil
}

enum LLM {
    /// The JSON schema the model must follow (sent as structured-output format).
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "minutes": ["type": "integer"],
                        "substeps": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string"],
                                    "minutes": ["type": "integer"],
                                ],
                                "required": ["title", "minutes"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["title", "minutes", "substeps"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["steps"],
        "additionalProperties": false,
    ]

    /// Ask the model for steps. Retries once if the reply isn't usable JSON.
    static func breakdown(system: String, user: String, settings: AppSettings, modelName: String, maxMinutes: Int) async throws -> [DraftStep] {
        if settings.engine == .apple {
            let steps = try await AppleModel.breakdown(system: system, user: user, temperature: settings.temperature)
            let cleaned = steps.compactMap { clamp($0, maxMinutes: maxMinutes, depth: 0) }
            guard !cleaned.isEmpty else {
                throw FriendlyError(
                    title: "The model didn't suggest any steps",
                    detail: "Apple's model came back with an empty list.",
                    fix: "Press Try again, or add the steps by hand below.")
            }
            return Array(cleaned.prefix(12))
        }
        for _ in 0..<2 {
            try Task.checkCancellation()
            let content = try await chat(system: system, user: user, settings: settings, modelName: modelName)
            if let steps = parseSteps(content, maxMinutes: maxMinutes), !steps.isEmpty {
                return steps
            }
        }
        throw FriendlyError(
            title: "The model's answer couldn't be read",
            detail: "It replied with something that wasn't a list of steps, two times in a row.",
            fix: "Press Try again, or add the steps by hand below.")
    }

    /// One non-streaming chat call. Returns the message text.
    static func chat(system: String, user: String, settings: AppSettings, modelName: String) async throws -> String {
        let messages: [[String: String]] = [
            ["role": "system", "content": system],
            ["role": "user", "content": user],
        ]
        var request: URLRequest
        var body: [String: Any]

        switch settings.engine {
        case .apple:
            return try await AppleModel.chat(system: system, user: user, temperature: settings.temperature)
        case .lmstudio:
            request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.lmstudioPort)/v1/chat/completions")!)
            body = [
                "model": modelName,
                "messages": messages,
                "temperature": settings.temperature,
                "stream": false,
                "response_format": [
                    "type": "json_schema",
                    "json_schema": ["name": "breakdown", "strict": true, "schema": schema],
                ],
            ]
        case .ollama:
            let base = settings.ollamaURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: base + "/api/chat") else {
                throw FriendlyError(title: "The Ollama URL looks wrong", detail: settings.ollamaURL, fix: "Settings → Model: use http://localhost:11434")
            }
            request = URLRequest(url: url)
            body = [
                "model": modelName,
                "messages": messages,
                "stream": false,
                "format": schema,
                "options": ["temperature": settings.temperature],
            ]
        }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            throw unreachable(settings: settings, underlying: e)
        }
        try Task.checkCancellation()

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if status >= 400 {
            let message = errorMessage(from: json) ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw modelProblem(settings: settings, message: message, status: status)
        }

        switch settings.engine {
        case .apple:
            break
        case .lmstudio:
            if let choices = json?["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                return content
            }
        case .ollama:
            if let msg = json?["message"] as? [String: Any], let content = msg["content"] as? String {
                return content
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func errorMessage(from json: [String: Any]?) -> String? {
        guard let json else { return nil }
        if let s = json["error"] as? String { return s }
        if let e = json["error"] as? [String: Any], let s = e["message"] as? String { return s }
        return nil
    }

    static func unreachable(settings: AppSettings, underlying: URLError) -> FriendlyError {
        switch settings.engine {
        case .apple:
            return FriendlyError(title: "Apple's model couldn't be reached", detail: underlying.localizedDescription, fix: "Press Try again.")
        case .lmstudio:
            if underlying.code == .timedOut {
                return FriendlyError(
                    title: "The model took too long to answer",
                    detail: "Gemma may still be loading, or the Mac is busy.",
                    fix: "Wait a few seconds and press Try again. If it keeps happening: Settings → Model → Restart model.")
            }
            return FriendlyError(
                title: "The model server isn't running",
                detail: "Break It Down couldn't reach the local model on port \(settings.lmstudioPort).",
                fix: "Click “Start model” at the bottom of the sidebar. From Terminal: ~/.lmstudio/bin/lms server start")
        case .ollama:
            return FriendlyError(
                title: "Ollama isn't running",
                detail: "Couldn't reach Ollama at \(settings.ollamaURL).",
                fix: "Click “Start model” at the bottom of the sidebar, or run in Terminal: ollama serve")
        }
    }

    static func modelProblem(settings: AppSettings, message: String, status: Int) -> FriendlyError {
        let lower = message.lowercased()
        let missing = lower.contains("not found") || lower.contains("no model") || lower.contains("not loaded") || lower.contains("does not exist") || status == 404
        switch settings.engine {
        case .apple:
            break
        case .lmstudio:
            if missing {
                return FriendlyError(
                    title: "The model isn't loaded",
                    detail: message,
                    fix: "Click “Start model” in the sidebar. From Terminal: ~/.lmstudio/bin/lms load \(settings.lmstudioModelKey)")
            }
        case .ollama:
            if missing {
                return FriendlyError(
                    title: "That model isn't installed in Ollama",
                    detail: message,
                    fix: "Run in Terminal: ollama pull \(settings.ollamaModel)")
            }
        }
        return FriendlyError(title: "The model returned an error", detail: message, fix: "Press Try again. If it repeats, check Settings → Model.")
    }

    // MARK: Parsing

    /// Pull the steps out of a reply, tolerating stray text, code fences and <think> blocks.
    static func parseSteps(_ raw: String, maxMinutes: Int) -> [DraftStep]? {
        var text = raw
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return nil }
        let endChar: Character = text[start] == "{" ? "}" : "]"
        guard let end = text.lastIndex(of: endChar), end > start else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let items: [Any]
        if let dict = obj as? [String: Any], let arr = dict["steps"] as? [Any] {
            items = arr
        } else if let arr = obj as? [Any] {
            items = arr
        } else {
            return nil
        }
        let steps = items.compactMap { parseItem($0, maxMinutes: maxMinutes, depth: 0) }
        return steps.isEmpty ? nil : Array(steps.prefix(12))
    }

    /// Apply the same limits the JSON parser does to steps from guided generation.
    private static func clamp(_ step: DraftStep, maxMinutes: Int, depth: Int) -> DraftStep? {
        guard !step.title.isEmpty else { return nil }
        var s = step
        if let m = s.minutes { s.minutes = min(max(m, 1), maxMinutes) }
        s.substeps = depth < 2 ? step.substeps.compactMap { clamp($0, maxMinutes: 15, depth: depth + 1) } : []
        return s
    }

    private static func parseItem(_ any: Any, maxMinutes: Int, depth: Int) -> DraftStep? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : DraftStep(title: t, minutes: nil)
        }
        guard let d = any as? [String: Any] else { return nil }
        let rawTitle = (d["title"] as? String) ?? (d["step"] as? String) ?? (d["name"] as? String) ?? ""
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        var minutes = intValue(d["minutes"])
        if let m = minutes { minutes = min(max(m, 1), maxMinutes) }
        var subs: [DraftStep] = []
        if depth < 2, let arr = d["substeps"] as? [Any] {
            subs = arr.compactMap { parseItem($0, maxMinutes: 15, depth: depth + 1) }
        }
        return DraftStep(title: title, minutes: minutes, substeps: subs)
    }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d.rounded())
        case let s as String: return Int(s.filter(\.isNumber))
        default: return nil
        }
    }
}
