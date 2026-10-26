import Foundation
import Observation

/// Running and pending "Break it down" requests, keyed by target:
/// a list id (break down the whole task) or a step id (break down that step further).
@MainActor
@Observable
final class Breakdowns {
    enum Phase: Equatable {
        case loading(String)
        case draft([DraftStep])
        case failed(FriendlyError)
    }

    struct Session: Equatable {
        var phase: Phase
        var listID: UUID
        var parentID: UUID?
    }

    var sessions: [UUID: Session] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func session(_ key: UUID) -> Session? { sessions[key] }

    func isLoading(_ key: UUID) -> Bool {
        if case .loading = sessions[key]?.phase { return true }
        return false
    }

    func start(listID: UUID, parentID: UUID?, store: Store, server: ModelServer) {
        let key = parentID ?? listID
        tasks[key]?.cancel()
        guard let list = store.list(listID) else { return }

        let system = store.prompts.system
        let user: String
        let maxMinutes: Int
        if let parentID, let step = list.steps.step(withID: parentID) {
            user = store.prompts.furtherMessage(step: step.title, parent: list.title, context: list.context)
            maxMinutes = 15
        } else {
            let task = list.breakdownText.trimmingCharacters(in: .whitespacesAndNewlines)
            user = store.prompts.breakdownMessage(task: task.isEmpty ? list.title : task, context: list.context)
            maxMinutes = 25
        }

        sessions[key] = Session(phase: .loading("Thinking…"), listID: listID, parentID: parentID)

        tasks[key] = Task { [weak self] in
            guard let self else { return }
            // If the model is still starting up, wait for it instead of failing.
            var waited = 0
            while case .starting = server.status, waited < 300 {
                self.sessions[key]?.phase = .loading("Waiting for the model to finish loading…")
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                waited += 1
            }
            if case .idle = server.status {
                server.start(store.settings)
                try? await Task.sleep(nanoseconds: 300_000_000)
                while case .starting = server.status {
                    self.sessions[key]?.phase = .loading("Starting the model…")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { return }
                }
            }
            if case .failed(let err) = server.status {
                self.sessions[key]?.phase = .failed(err)
                return
            }
            self.sessions[key]?.phase = .loading("Thinking…")
            do {
                let steps = try await LLM.breakdown(system: system, user: user, settings: store.settings,
                                                    modelName: server.activeModelName, maxMinutes: maxMinutes)
                if Task.isCancelled { return }
                self.sessions[key]?.phase = .draft(steps)
            } catch is CancellationError {
                return
            } catch let e as FriendlyError {
                self.sessions[key]?.phase = .failed(e)
            } catch {
                self.sessions[key]?.phase = .failed(FriendlyError(title: "Something went wrong", detail: error.localizedDescription, fix: "Press Try again."))
            }
        }
    }

    func cancel(_ key: UUID) {
        tasks[key]?.cancel()
        tasks[key] = nil
        sessions[key] = nil
    }

    func dismiss(_ key: UUID) { cancel(key) }

    func removeDraftStep(_ key: UUID, _ id: UUID) {
        guard case .draft(var steps) = sessions[key]?.phase else { return }
        steps.removeAll { $0.id == id }
        for i in steps.indices { steps[i].substeps.removeAll { $0.id == id } }
        sessions[key]?.phase = .draft(steps)
    }

    func accept(_ key: UUID, store: Store) {
        guard let s = sessions[key], case .draft(let steps) = s.phase else { return }
        store.acceptDraft(s.listID, into: s.parentID, steps)
        cancel(key)
    }

    func regenerate(_ key: UUID, store: Store, server: ModelServer) {
        guard let s = sessions[key] else { return }
        start(listID: s.listID, parentID: s.parentID, store: store, server: server)
    }
}
