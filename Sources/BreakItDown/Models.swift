import Foundation

/// Max nesting: a step, its sub-steps, and their sub-steps (3 levels).
let maxLevels = 3

// MARK: - Step

struct Step: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var done: Bool = false
    var minutes: Int? = nil
    var note: String? = nil
    var children: [Step] = []
    /// nil = automatic (open only if it contains the current step)
    var expanded: Bool? = nil

    init(title: String, minutes: Int? = nil, note: String? = nil, children: [Step] = []) {
        self.title = title
        self.minutes = minutes
        self.note = note
        self.children = children
    }

    enum CodingKeys: String, CodingKey { case id, title, done, minutes, note, children, expanded }

    var hasChildren: Bool { !children.isEmpty }

    /// Number of levels in this subtree (a leaf is 1).
    var height: Int { 1 + (children.map(\.height).max() ?? 0) }

    var leafCount: Int { children.isEmpty ? 1 : children.reduce(0) { $0 + $1.leafCount } }
    var doneLeafCount: Int { children.isEmpty ? (done ? 1 : 0) : children.reduce(0) { $0 + $1.doneLeafCount } }

    var doneChildCount: Int { children.filter(\.done).count }

    func contains(_ target: UUID) -> Bool {
        id == target || children.contains { $0.contains(target) }
    }

    mutating func setDoneRecursively(_ value: Bool) {
        done = value
        for i in children.indices { children[i].setDoneRecursively(value) }
    }
}

extension Step {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        done = (try? c.decode(Bool.self, forKey: .done)) ?? false
        if let m = try? c.decode(Int.self, forKey: .minutes) {
            minutes = m
        } else if let d = try? c.decode(Double.self, forKey: .minutes) {
            minutes = Int(d)
        } else {
            minutes = nil
        }
        note = try? c.decode(String.self, forKey: .note)
        children = (try? c.decode([Step].self, forKey: .children)) ?? []
        expanded = try? c.decode(Bool.self, forKey: .expanded)
    }
}

// MARK: - TaskList

struct TaskList: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var steps: [Step] = []
    var isExample: Bool = false
    var breakdownText: String = ""
    var context: String = ""
    var createdAt: Date = Date()

    init(title: String, steps: [Step] = [], isExample: Bool = false) {
        self.title = title
        self.steps = steps
        self.isExample = isExample
        self.breakdownText = title
    }

    enum CodingKeys: String, CodingKey { case id, title, steps, isExample, breakdownText, context, createdAt }

    var totalLeaves: Int { steps.reduce(0) { $0 + $1.leafCount } }
    var doneLeaves: Int { steps.reduce(0) { $0 + $1.doneLeafCount } }
    var progress: Double { totalLeaves == 0 ? 0 : Double(doneLeaves) / Double(totalLeaves) }
}

extension TaskList {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        steps = (try? c.decode([Step].self, forKey: .steps)) ?? []
        isExample = (try? c.decode(Bool.self, forKey: .isExample)) ?? false
        breakdownText = (try? c.decode(String.self, forKey: .breakdownText)) ?? ""
        context = (try? c.decode(String.self, forKey: .context)) ?? ""
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - AppData

struct AppData: Codable {
    var version: Int = 1
    var lists: [TaskList] = []

    init(lists: [TaskList] = []) { self.lists = lists }

    enum CodingKeys: String, CodingKey { case version, lists }
}

extension AppData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        lists = (try? c.decode([TaskList].self, forKey: .lists)) ?? []
    }
}

// MARK: - Tree helpers

extension Array where Element == Step {
    /// Index path to the step with this id.
    func path(of id: UUID) -> [Int]? {
        for (i, s) in self.enumerated() {
            if s.id == id { return [i] }
            if let sub = s.children.path(of: id) { return [i] + sub }
        }
        return nil
    }

    func step(at path: [Int]) -> Step? {
        guard let first = path.first, indices.contains(first) else { return nil }
        if path.count == 1 { return self[first] }
        return self[first].children.step(at: [Int](path.dropFirst()))
    }

    func step(withID id: UUID) -> Step? {
        guard let p = path(of: id) else { return nil }
        return step(at: p)
    }

    mutating func updateStep(at path: [Int], _ change: (inout Step) -> Void) {
        guard let first = path.first, indices.contains(first) else { return }
        if path.count == 1 {
            change(&self[first])
        } else {
            self[first].children.updateStep(at: [Int](path.dropFirst()), change)
        }
    }

    /// Run `change` on the sibling array that contains the item at `path` (path's last index is into that array).
    mutating func updateSiblings(of path: [Int], _ change: (inout [Step]) -> Void) {
        if path.count <= 1 {
            change(&self)
        } else {
            updateStep(at: [Int](path.dropLast())) { parent in change(&parent.children) }
        }
    }

    @discardableResult
    mutating func removeStep(at path: [Int]) -> Step? {
        var removed: Step?
        updateSiblings(of: path) { siblings in
            if let last = path.last, siblings.indices.contains(last) {
                removed = siblings.remove(at: last)
            }
        }
        return removed
    }

    mutating func insertStep(_ step: Step, at path: [Int]) {
        updateSiblings(of: path) { siblings in
            let idx = Swift.min(Swift.max(path.last ?? 0, 0), siblings.count)
            siblings.insert(step, at: idx)
        }
    }

    /// A parent is done exactly when all of its children are done.
    mutating func syncDone() {
        for i in indices where !self[i].children.isEmpty {
            self[i].children.syncDone()
            self[i].done = self[i].children.allSatisfy(\.done)
        }
    }

    /// The first unchecked leaf in reading order: "the step I'm on now".
    func firstUncheckedLeaf() -> Step? {
        for s in self where !s.done {
            if s.children.isEmpty { return s }
            if let leaf = s.children.firstUncheckedLeaf() { return leaf }
        }
        return nil
    }

    /// Flattened ids in display order, honoring which branches are open.
    func visibleIDs(isOpen: (Step) -> Bool) -> [UUID] {
        var out: [UUID] = []
        for s in self {
            out.append(s.id)
            if s.hasChildren && isOpen(s) {
                out += s.children.visibleIDs(isOpen: isOpen)
            }
        }
        return out
    }
}
