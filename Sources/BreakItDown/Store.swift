import Foundation
import Observation
import AppKit

/// All app state. Every change is written to data.json right away (atomic: temp file + rename).
@MainActor
@Observable
final class Store {
    var data = AppData()
    var settings = AppSettings() { didSet { if settings != oldValue { saveSettings() } } }
    var prompts = Prompts.defaults { didSet { if prompts != oldValue { savePrompts() } } }

    var selectedListID: UUID?
    /// The main selected step (keyboard focus, anchor for Shift-click). Changing it drops the extra selection.
    var selectedStepID: UUID? { didSet { if selectedStepID != oldValue { extraSelectedIDs = [] } } }
    /// Other steps selected along with `selectedStepID` (Command- or Shift-click).
    var extraSelectedIDs: Set<UUID> = []
    var editingStepID: UUID?
    /// Where a drag is currently hovering. Kept here, not in each row, so it can always be cleared in one place.
    var dropTarget: (id: UUID, zone: StepDropZone)?
    var renamingListID: UUID?

    private struct UndoEntry { var label: String; var data: AppData }
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    /// Set after a delete or import, so the toast can offer Undo. Cleared by the next edit.
    var undoToast: String?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoActionName: String? { undoStack.last?.label }
    var redoActionName: String? { redoStack.last?.label }

    var saveError: String?

    // MARK: Files

    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("BreakItDown", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var dataURL: URL { dir.appendingPathComponent("data.json") }
    static var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    static var promptsURL: URL { dir.appendingPathComponent("prompts.json") }

    init() {
        load()
    }

    func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: Store.settingsURL), let s = try? dec.decode(AppSettings.self, from: d) {
            settings = s
        }
        if let d = try? Data(contentsOf: Store.promptsURL), let p = try? dec.decode(Prompts.self, from: d) {
            prompts = p
        } else {
            savePrompts()
        }
        if let d = try? Data(contentsOf: Store.dataURL), let a = try? dec.decode(AppData.self, from: d) {
            data = a
        } else {
            data = AppData(lists: [Examples.list])
            save()
        }
        selectedListID = data.lists.first?.id
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            let bytes = try enc.encode(value)
            // .atomic writes to a temporary file, then renames it over the original.
            try bytes.write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    func save() { write(data, to: Store.dataURL) }
    func saveSettings() { write(settings, to: Store.settingsURL) }
    func savePrompts() { write(prompts, to: Store.promptsURL) }

    /// Every edit goes through here.
    private func mutate(keepUndo: Bool = false, _ change: (inout AppData) -> Void) {
        dropTarget = nil
        if !keepUndo { undoToast = nil }
        change(&data)
        save()
    }

    // MARK: Lists

    func list(_ id: UUID?) -> TaskList? {
        guard let id else { return nil }
        return data.lists.first { $0.id == id }
    }

    var selectedList: TaskList? { list(selectedListID) }

    private func listIndex(_ id: UUID) -> Int? { data.lists.firstIndex { $0.id == id } }

    func updateList(_ id: UUID, _ change: (inout TaskList) -> Void) {
        guard let i = listIndex(id) else { return }
        mutate { change(&$0.lists[i]) }
    }

    @discardableResult
    func newList(title: String = "") -> UUID {
        let l = TaskList(title: title)
        mutate { $0.lists.insert(l, at: 0) }
        selectedListID = l.id
        selectedStepID = nil
        return l.id
    }

    func renameList(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateList(id) { l in
            let old = l.title
            l.title = t.isEmpty ? "Untitled task" : t
            if l.breakdownText.isEmpty || l.breakdownText == old { l.breakdownText = l.title }
        }
    }

    func deleteList(_ id: UUID) {
        guard let i = listIndex(id) else { return }
        let snapshot = data
        let name = data.lists[i].title
        mutate { $0.lists.remove(at: i) }
        pushUndo(snapshot, label: "Deleted “\(name)”", toast: true)
        if selectedListID == id { selectedListID = data.lists.first?.id }
    }

    func moveLists(from source: IndexSet, to destination: Int) {
        mutate { $0.lists.move(fromOffsets: source, toOffset: destination) }
    }

    func moveList(_ id: UUID, by delta: Int) {
        guard let i = listIndex(id) else { return }
        let j = i + delta
        guard data.lists.indices.contains(j) else { return }
        mutate { $0.lists.swapAt(i, j) }
    }

    // MARK: Steps

    func step(_ listID: UUID, _ stepID: UUID) -> Step? {
        list(listID)?.steps.step(withID: stepID)
    }

    func level(of stepID: UUID, in listID: UUID) -> Int {
        (list(listID)?.steps.path(of: stepID)?.count ?? 1) - 1
    }

    func updateStep(_ listID: UUID, _ stepID: UUID, _ change: (inout Step) -> Void) {
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID) else { return }
            l.steps.updateStep(at: p, change)
            l.steps.syncDone()
        }
    }

    func toggle(_ listID: UUID, _ stepID: UUID) {
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID) else { return }
            l.steps.updateStep(at: p) { s in s.setDoneRecursively(!s.done) }
            l.steps.syncDone()
        }
    }

    func setDone(_ listID: UUID, _ stepID: UUID, _ value: Bool) {
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID) else { return }
            l.steps.updateStep(at: p) { s in s.setDoneRecursively(value) }
            l.steps.syncDone()
        }
    }

    /// Add a step at the end of the list, or after/inside a given step.
    @discardableResult
    func addStep(_ listID: UUID, title: String, after siblingID: UUID? = nil, inside parentID: UUID? = nil) -> UUID? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let s = Step(title: t)
        updateList(listID) { l in
            if let parentID, let pp = l.steps.path(of: parentID), pp.count < maxLevels {
                l.steps.updateStep(at: pp) { parent in
                    parent.children.append(s)
                    parent.expanded = true
                }
            } else if let siblingID, var sp = l.steps.path(of: siblingID) {
                sp[sp.count - 1] += 1
                l.steps.insertStep(s, at: sp)
            } else {
                l.steps.append(s)
            }
            l.steps.syncDone()
        }
        return s.id
    }

    /// Add one step per non-empty line, in order. Strips list markers ("-", "•", "1.") from each line.
    /// Returns the id of the last step added.
    @discardableResult
    func addSteps(fromLines text: String, _ listID: UUID, after siblingID: UUID? = nil) -> UUID? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"^\s*(?:[-*•–]|\d+[.)])\s+"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var last = siblingID
        var added: UUID?
        for line in lines {
            if let id = addStep(listID, title: line, after: last) {
                last = id
                added = id
            }
        }
        return added
    }

    func editStep(_ listID: UUID, _ stepID: UUID, title: String, minutes: Int?, note: String?) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        updateStep(listID, stepID) { s in
            if !t.isEmpty { s.title = t }
            s.minutes = minutes.map { min(max($0, 1), 600) }
            let n = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            s.note = n.isEmpty ? nil : n
        }
    }

    var selectedSet: Set<UUID> {
        extraSelectedIDs.union(selectedStepID.map { [$0] } ?? [])
    }

    enum SelectMode { case replace, toggle, range }

    func selectStep(_ id: UUID, in listID: UUID, mode: SelectMode) {
        switch mode {
        case .replace:
            selectedStepID = id
            extraSelectedIDs = []
        case .toggle:
            var set = selectedSet
            if set.contains(id) { set.remove(id) } else { set.insert(id) }
            let primary = set.contains(id) ? id : visibleStepIDs(listID).first(where: set.contains)
            selectedStepID = primary
            extraSelectedIDs = primary.map { set.subtracting([$0]) } ?? []
        case .range:
            let visible = visibleStepIDs(listID)
            guard let anchor = selectedStepID, let a = visible.firstIndex(of: anchor), let b = visible.firstIndex(of: id) else {
                selectStep(id, in: listID, mode: .replace)
                return
            }
            extraSelectedIDs = Set(visible[min(a, b)...max(a, b)]).subtracting([anchor])
        }
    }

    /// Delete several steps as one undoable action.
    func deleteSteps(_ listID: UUID, _ ids: Set<UUID>) {
        guard let l = list(listID) else { return }
        if ids.count == 1, let only = ids.first { deleteStep(listID, only); return }
        let visible = l.steps.visibleIDs { self.isOpen($0, in: l) }
        let firstIdx = visible.firstIndex(where: ids.contains) ?? 0
        let snapshot = data
        var removed = 0
        updateList(listID) { l in
            for id in ids {
                // A step nested under one already removed is gone, so its path is nil.
                if let p = l.steps.path(of: id), l.steps.removeStep(at: p) != nil { removed += 1 }
            }
            l.steps.syncDone()
        }
        guard removed > 0 else { return }
        pushUndo(snapshot, label: "Deleted \(removed) steps", toast: true)
        let remaining = visibleStepIDs(listID).filter { !ids.contains($0) }
        selectedStepID = remaining.isEmpty ? nil : remaining[min(max(firstIdx - 1, 0), remaining.count - 1)]
        extraSelectedIDs = []
    }

    func deleteStep(_ listID: UUID, _ stepID: UUID) {
        guard let l = list(listID), let p = l.steps.path(of: stepID), let s = l.steps.step(at: p) else { return }
        // Pick a neighbor to select next.
        let visible = l.steps.visibleIDs { self.isOpen($0, in: l) }
        let idx = visible.firstIndex(of: stepID) ?? 0
        let snapshot = data
        updateList(listID) { l in
            l.steps.removeStep(at: p)
            l.steps.syncDone()
        }
        pushUndo(snapshot, label: "Deleted “\(s.title)”", toast: true)
        if selectedStepID == stepID || (selectedStepID.map { s.contains($0) } ?? false) {
            let remaining = list(listID)?.steps.visibleIDs { self.isOpen($0, in: l) } ?? []
            selectedStepID = remaining.isEmpty ? nil : remaining[min(max(idx - 1, 0), remaining.count - 1)]
        }
    }

    private func pushUndo(_ snapshot: AppData, label: String, toast: Bool = false) {
        undoStack.append(UndoEntry(label: label, data: snapshot))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack = []
        undoToast = toast ? label : nil
    }

    /// Record an undo step for a change made since `before`, if it changed anything.
    private func commitUndo(_ before: AppData, _ label: String) {
        guard data.lists != before.lists else { return }
        pushUndo(before, label: label)
    }

    private func restore(_ entry: UndoEntry) {
        data = entry.data
        undoToast = nil
        dropTarget = nil
        save()
        if list(selectedListID) == nil { selectedListID = data.lists.first?.id }
        if let sel = selectedStepID, let l = selectedList, l.steps.path(of: sel) == nil { selectedStepID = nil }
        extraSelectedIDs = extraSelectedIDs.filter { id in selectedList?.steps.path(of: id) != nil }
        editingStepID = nil
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(label: entry.label, data: data))
        restore(entry)
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(label: entry.label, data: data))
        restore(entry)
    }

    /// Move within siblings.
    func moveStep(_ listID: UUID, _ stepID: UUID, by delta: Int) {
        let before = data
        defer { commitUndo(before, "Move") }
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID), let last = p.last else { return }
            l.steps.updateSiblings(of: p) { sib in
                let j = last + delta
                if sib.indices.contains(j) { sib.swapAt(last, j) }
            }
        }
    }

    func canIndent(_ listID: UUID, _ stepID: UUID) -> Bool {
        guard let l = list(listID), let p = l.steps.path(of: stepID), let last = p.last, last > 0,
              let s = l.steps.step(at: p) else { return false }
        return p.count + s.height <= maxLevels
    }

    /// Make the step the last child of the step above it.
    func indent(_ listID: UUID, _ stepID: UUID) {
        let before = data
        defer { commitUndo(before, "Indent") }
        guard canIndent(listID, stepID) else { return }
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID), let last = p.last, let s = l.steps.removeStep(at: p) else { return }
            var prev = p
            prev[prev.count - 1] = last - 1
            l.steps.updateStep(at: prev) { parent in
                parent.children.append(s)
                parent.expanded = true
            }
            l.steps.syncDone()
        }
    }

    /// Move the step out to sit right after its parent.
    func outdent(_ listID: UUID, _ stepID: UUID) {
        let before = data
        defer { commitUndo(before, "Outdent") }
        updateList(listID) { l in
            guard let p = l.steps.path(of: stepID), p.count > 1, let s = l.steps.removeStep(at: p) else { return }
            var target = Array(p.dropLast())
            target[target.count - 1] += 1
            l.steps.insertStep(s, at: target)
            l.steps.syncDone()
        }
    }

    /// Drag and drop: put `dragged` right before `target` (same parent as target).
    func moveStep(_ listID: UUID, _ dragged: UUID, before target: UUID) {
        let before = data
        defer { commitUndo(before, "Move") }
        guard dragged != target, let l = list(listID),
              let ds = l.steps.step(withID: dragged), !ds.contains(target),
              let tp = l.steps.path(of: target), tp.count - 1 + ds.height <= maxLevels else { return }
        updateList(listID) { l in
            guard let dp = l.steps.path(of: dragged), let s = l.steps.removeStep(at: dp),
                  let newTarget = l.steps.path(of: target) else { return }
            l.steps.insertStep(s, at: newTarget)
            l.steps.syncDone()
        }
    }

    enum MoveDestination {
        case before(UUID)   // as siblings, just above this step
        case inside(UUID)   // as the last sub-steps of this step
        case end            // bottom of the top level
    }

    /// Move several steps at once, keeping their on-screen order. Steps that would break the nesting
    /// limit, or that would end up inside themselves, are left where they are.
    func moveSteps(_ listID: UUID, _ ids: [UUID], to dest: MoveDestination) {
        let before = data
        defer { commitUndo(before, "Move") }
        let wanted = Set(ids)
        updateList(listID) { l in
            // Top-most selected steps only (children travel with their parent), in document order.
            func collect(_ steps: [Step], underWanted: Bool, _ out: inout [Step]) {
                for s in steps {
                    let w = wanted.contains(s.id)
                    if w && !underWanted { out.append(s) }
                    collect(s.children, underWanted: underWanted || w, &out)
                }
            }
            let targetID: UUID? = { switch dest { case .before(let t), .inside(let t): return t; case .end: return nil } }()
            let targetDepth = targetID.flatMap { l.steps.path(of: $0)?.count } ?? 0   // levels at and above the target
            var top: [Step] = []
            collect(l.steps, underWanted: false, &top)
            let movers = top.filter { s in
                if let t = targetID, s.contains(t) { return false }   // can't go inside itself
                return true
            }.filter { s in
                switch dest {
                case .before: return targetDepth - 1 + s.height <= maxLevels
                case .inside: return targetDepth + s.height <= maxLevels
                case .end: return true
                }
            }
            guard !movers.isEmpty else { return }

            var moved: [Step] = []
            for m in movers {
                if let p = l.steps.path(of: m.id), let s = l.steps.removeStep(at: p) { moved.append(s) }
            }
            switch dest {
            case .before(let t):
                guard var tp = l.steps.path(of: t) else { l.steps += moved; break }
                for s in moved { l.steps.insertStep(s, at: tp); tp[tp.count - 1] += 1 }
            case .inside(let t):
                guard let tp = l.steps.path(of: t) else { l.steps += moved; break }
                l.steps.updateStep(at: tp) { parent in
                    parent.children += moved
                    parent.expanded = true
                }
            case .end:
                l.steps += moved
            }
            l.steps.syncDone()
        }
    }

    func moveStepToEnd(_ listID: UUID, _ dragged: UUID) {
        let before = data
        defer { commitUndo(before, "Move") }
        updateList(listID) { l in
            guard let dp = l.steps.path(of: dragged), let s = l.steps.removeStep(at: dp) else { return }
            l.steps.append(s)
            l.steps.syncDone()
        }
    }

    func setExpanded(_ listID: UUID, _ stepID: UUID, _ value: Bool) {
        guard let i = listIndex(listID), let p = data.lists[i].steps.path(of: stepID) else { return }
        // UI state only: don't clear undo for this.
        mutate(keepUndo: true) { d in
            d.lists[i].steps.updateStep(at: p) { s in s.expanded = value }
        }
    }

    /// The step I'm currently on.
    func currentStepID(in list: TaskList) -> UUID? { list.steps.firstUncheckedLeaf()?.id }

    /// Collapsed by default except the branch holding the current step.
    func isOpen(_ step: Step, in list: TaskList) -> Bool {
        if let e = step.expanded { return e }
        guard let cur = currentStepID(in: list) else { return false }
        return step.contains(cur)
    }

    func visibleStepIDs(_ listID: UUID) -> [UUID] {
        guard let l = list(listID) else { return [] }
        return l.steps.visibleIDs { self.isOpen($0, in: l) }
    }

    func moveSelection(_ listID: UUID, by delta: Int) {
        let ids = visibleStepIDs(listID)
        guard !ids.isEmpty else { return }
        if let cur = selectedStepID, let i = ids.firstIndex(of: cur) {
            selectedStepID = ids[min(max(i + delta, 0), ids.count - 1)]
        } else {
            selectedStepID = delta > 0 ? ids.first : ids.last
        }
    }

    // MARK: Accepting drafts

    func acceptDraft(_ listID: UUID, into parentID: UUID?, _ drafts: [DraftStep]) {
        updateList(listID) { l in
            if let parentID, let pp = l.steps.path(of: parentID) {
                let extra = maxLevels - pp.count - 1   // how many levels below the new children
                guard extra >= 0 else { return }
                let new = drafts.map { $0.toStep(extraLevels: extra) }
                l.steps.updateStep(at: pp) { parent in
                    let wasDone = parent.done
                    parent.children += new
                    parent.expanded = true
                    if wasDone { for i in parent.children.indices { parent.children[i].setDoneRecursively(false) } }
                }
            } else {
                l.steps += drafts.map { $0.toStep(extraLevels: maxLevels - 1) }
            }
            l.steps.syncDone()
        }
    }

    // MARK: Import / export

    func exportJSON() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(data)
    }

    func importJSON(_ bytes: Data) throws {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let incoming = try dec.decode(AppData.self, from: bytes)
        guard !incoming.lists.isEmpty else {
            throw FriendlyError(title: "Nothing to import", detail: "That file has no lists in it.")
        }
        let snapshot = data
        mutate { d in
            // Add imported lists; replace any with the same id.
            for l in incoming.lists {
                if let i = d.lists.firstIndex(where: { $0.id == l.id }) { d.lists[i] = l } else { d.lists.append(l) }
            }
        }
        pushUndo(snapshot, label: "Imported \(incoming.lists.count) list(s)", toast: true)
        selectedListID = incoming.lists.first?.id
    }
}

// MARK: - First-launch example

enum Examples {
    static var list: TaskList {
        var l = TaskList(title: "Example: Clean my room", isExample: true)
        l.breakdownText = "Clean my room"
        l.context = "It's pretty messy, about an hour total"
        l.steps = [
            Step(title: "Put on music and grab one trash bag", minutes: 2),
            Step(title: "Clear the floor", minutes: 15, children: [
                Step(title: "Throw obvious trash in the bag", minutes: 5),
                Step(title: "Put dirty clothes in the hamper", minutes: 5),
                Step(title: "Stack everything else on the bed", minutes: 5),
            ]),
            Step(title: "Sort the pile on the bed", minutes: 20, children: [
                Step(title: "Put clean clothes away", minutes: 8),
                Step(title: "Return dishes to the kitchen", minutes: 4),
                Step(title: "Put papers in one folder", minutes: 5),
            ]),
            Step(title: "Wipe the desk and nightstand", minutes: 5),
            Step(title: "Take the trash bag out", minutes: 3),
        ]
        l.steps[0].done = true
        l.steps[0].note = "This is an example list. Delete it whenever you like."
        return l
    }
}
