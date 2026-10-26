import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (Apple Intelligence, macOS 26+). No server, no download beyond the OS.
enum AppleModel {
    /// Nil when the model can be used now; otherwise a plain-language reason with the fix.
    static func unavailableReason() -> (error: FriendlyError, mayResolveSoon: Bool)? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return (needsNewerMacOS, false) }
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return (FriendlyError(
                title: "This Mac can't run Apple Intelligence",
                detail: "Apple's on-device model needs a Mac with Apple silicon.",
                fix: "Settings → Model → Engine: choose LM Studio or Ollama."), false)
        case .unavailable(.appleIntelligenceNotEnabled):
            return (FriendlyError(
                title: "Apple Intelligence is turned off",
                detail: "Break It Down uses Apple's on-device model, which needs Apple Intelligence.",
                fix: "System Settings → Apple Intelligence & Siri: turn on Apple Intelligence. Or pick another engine in Settings → Model."), false)
        case .unavailable(.modelNotReady):
            return (FriendlyError(
                title: "Apple's model is still downloading",
                detail: "macOS is getting the on-device model ready. This happens once.",
                fix: "Keep the Mac on power and Wi-Fi, then click Start model in a few minutes."), true)
        case .unavailable:
            return (FriendlyError(
                title: "Apple's on-device model isn't available",
                detail: "macOS reported it can't be used right now.",
                fix: "Settings → Model → Engine: choose LM Studio or Ollama."), false)
        }
        #else
        return (needsNewerMacOS, false)
        #endif
    }

    static let needsNewerMacOS = FriendlyError(
        title: "Apple's on-device model needs macOS 26",
        detail: "This Mac is on an older macOS, or the app was built without Apple's FoundationModels.",
        fix: "Update macOS, or pick LM Studio or Ollama in Settings → Model → Engine.")

    /// Load the model into memory ahead of the first request.
    static func prewarm(instructions: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            LanguageModelSession(instructions: instructions).prewarm()
        }
        #endif
    }

    /// Steps via guided generation, so the reply always matches the shape.
    static func breakdown(system: String, user: String, temperature: Double) async throws -> [DraftStep] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw needsNewerMacOS }
        let session = LanguageModelSession(instructions: system)
        do {
            let response = try await session.respond(
                to: user,
                generating: GeneratedBreakdown.self,
                options: GenerationOptions(temperature: temperature))
            return response.content.steps.map(\.draft)
        } catch let e as LanguageModelSession.GenerationError {
            throw friendly(e)
        }
        #else
        throw needsNewerMacOS
        #endif
    }

    /// Plain text reply (used by Test connection).
    static func chat(system: String, user: String, temperature: Double) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { throw needsNewerMacOS }
        let session = LanguageModelSession(instructions: system)
        do {
            return try await session.respond(to: user, options: GenerationOptions(temperature: temperature)).content
        } catch let e as LanguageModelSession.GenerationError {
            throw friendly(e)
        }
        #else
        throw needsNewerMacOS
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func friendly(_ e: LanguageModelSession.GenerationError) -> FriendlyError {
        switch e {
        case .exceededContextWindowSize:
            return FriendlyError(
                title: "That task is too long for Apple's model",
                detail: "The task and its context are more than the on-device model can read at once.",
                fix: "Shorten the context, or pick LM Studio or Ollama in Settings → Model.")
        case .guardrailViolation, .refusal:
            return FriendlyError(
                title: "Apple's model declined this one",
                detail: "Its safety filter blocked the request.",
                fix: "Reword the task, add the steps by hand, or pick another engine in Settings → Model.")
        case .unsupportedLanguageOrLocale:
            return FriendlyError(
                title: "Apple's model doesn't support this language",
                detail: e.localizedDescription,
                fix: "Write the task in a supported language, or pick another engine in Settings → Model.")
        case .assetsUnavailable:
            return FriendlyError(
                title: "Apple's model isn't ready",
                detail: "macOS hasn't finished setting up the on-device model.",
                fix: "Wait a few minutes and press Try again.")
        case .rateLimited, .concurrentRequests:
            return FriendlyError(
                title: "Apple's model is busy",
                detail: e.localizedDescription,
                fix: "Wait a moment and press Try again.")
        default:
            return FriendlyError(
                title: "Apple's model returned an error",
                detail: e.localizedDescription,
                fix: "Press Try again. If it repeats, check Settings → Model.")
        }
    }
    #endif
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
struct GeneratedBreakdown {
    @Guide(description: "The steps, in the order the person would do them", .count(1...12))
    var steps: [GeneratedStep]
}

@available(macOS 26.0, *)
@Generable
struct GeneratedStep {
    @Guide(description: "Starts with a verb, under 12 words")
    var title: String
    @Guide(description: "Minutes this step takes", .range(1...25))
    var minutes: Int
    @Guide(description: "Smaller parts; empty unless the step has several parts or takes over 15 minutes", .maximumCount(6))
    var substeps: [GeneratedSubstep]

    var draft: DraftStep {
        DraftStep(title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                  minutes: minutes,
                  substeps: substeps.map(\.draft))
    }
}

@available(macOS 26.0, *)
@Generable
struct GeneratedSubstep {
    @Guide(description: "Starts with a verb, under 12 words")
    var title: String
    @Guide(description: "Minutes this substep takes", .range(1...15))
    var minutes: Int

    var draft: DraftStep {
        DraftStep(title: title.trimmingCharacters(in: .whitespacesAndNewlines), minutes: minutes)
    }
}
#endif
