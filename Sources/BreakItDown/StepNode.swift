import SwiftUI
import UniformTypeIdentifiers

/// One step, plus (when open) its sub-steps, recursively.
struct StepNode: View {
    let step: Step
    let list: TaskList
    let level: Int
    var focusSteps: () -> Void

    @Environment(Store.self) private var store
    @Environment(ModelServer.self) private var server
    @Environment(Breakdowns.self) private var breakdowns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var rowHeight: CGFloat = 40

    private var listID: UUID { list.id }
    private var isOpen: Bool { store.isOpen(step, in: list) }
    private var isSelected: Bool { store.selectedStepID == step.id || store.extraSelectedIDs.contains(step.id) }
    private var isCurrent: Bool { store.currentStepID(in: list) == step.id }
    private var dropZone: StepDropZone? {
        store.dropTarget?.id == step.id ? store.dropTarget?.zone : nil
    }
    private var isEditing: Bool { store.editingStepID == step.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            if let session = breakdowns.session(step.id) {
                BreakdownSessionView(key: step.id, session: session, onAddByHand: {
                    breakdowns.dismiss(step.id)
                    store.editingStepID = nil
                    if let id = store.addStep(listID, title: "New step", inside: step.id) {
                        store.selectedStepID = id
                        store.editingStepID = id
                    }
                })
                .padding(.leading, 60)
                .padding(.vertical, 4)
            }
            if step.hasChildren && isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(step.children) { child in
                        StepNode(step: child, list: list, level: level + 1, focusSteps: focusSteps)
                    }
                }
                .padding(.leading, 30)
            }
        }
    }

    // MARK: Row

    private var row: some View {
        HStack(alignment: .center, spacing: 10) {
            // Chevron
            if step.hasChildren {
                Button {
                    toggleOpen()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(isOpen ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: 20, height: 28)
            }

            // Checkbox
            Button {
                store.toggle(listID, step.id)
            } label: {
                Image(systemName: step.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(step.done ? Palette.accent : Color.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(step.done ? "Mark not done" : "Mark done")

            // Title / editor
            if isEditing {
                StepEditor(step: step, listID: listID, onFinish: focusSteps)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.title)
                        .font(level == 0 ? .body.weight(.medium) : .body)
                        .strikethrough(step.done, color: .secondary)
                        .foregroundStyle(step.done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = step.note, !note.isEmpty {
                        Text(note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !isEditing {
                if breakdowns.isLoading(step.id) {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { breakdowns.cancel(step.id) }
                        .controlSize(.small)
                }
                if step.hasChildren {
                    HStack(spacing: 6) {
                        Text("\(step.doneChildCount)/\(step.children.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        ProgressView(value: Double(step.doneLeafCount), total: Double(max(step.leafCount, 1)))
                            .progressViewStyle(.linear)
                            .tint(Palette.accent)
                            .frame(width: 36)
                    }
                }
                if let m = step.minutes {
                    Text("\(m) min")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                actionsMenu
                    .opacity(hovering || isSelected ? 1 : 0.0)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Palette.accent.opacity(0.13) : (hovering ? Color.primary.opacity(0.045) : Color.clear))
        )
        .overlay(alignment: .leading) {
            if isCurrent {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.accent)
                    .frame(width: 3)
                    .padding(.vertical, 6)
                    .accessibilityLabel("Current step")
            }
        }
        .overlay(alignment: .top) {
            if dropZone == .before {
                Rectangle().fill(Palette.accent).frame(height: 2)
            }
        }
        .overlay {
            if dropZone == .inside {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Palette.accent, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.1)))
                    .allowsHitTesting(false)
            }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { rowHeight = g.size.height }
                .onChange(of: g.size.height) { _, h in rowHeight = h }
        })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                store.selectStep(step.id, in: listID, mode: .toggle)
            } else if mods.contains(.shift) {
                store.selectStep(step.id, in: listID, mode: .range)
            } else {
                select()
            }
            focusSteps()
        }
        // Simultaneous, so the single click above fires at once instead of waiting to rule out a double click.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            select()
            store.editingStepID = step.id
        })
        .draggable(dragPayload) {
            Text(dragIDs.count > 1 ? "\(dragIDs.count) steps" : step.title)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .onDrop(of: [.plainText], delegate: StepDropDelegate(
            zoneAt: { y in
                // Top edge: drop above this step. Anywhere else: drop inside it as sub-steps (if there's room).
                y < rowHeight * 0.3 || level >= maxLevels - 1 ? .before : .inside
            },
            setZone: { zone in
                if let zone { store.dropTarget = (step.id, zone) }
                else if store.dropTarget?.id == step.id { store.dropTarget = nil }
            },
            perform: { ids, zone in
                store.moveSteps(listID, ids, to: zone == .inside ? .inside(step.id) : .before(step.id))
            }))
        .contextMenu { menuItems }
    }

    private var actionsMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    /// Right-clicking a step inside the selection acts on the whole selection; otherwise on just that step.
    private var targets: Set<UUID> {
        isSelected ? store.selectedSet : [step.id]
    }

    @ViewBuilder
    private var menuItems: some View {
        if targets.count > 1 {
            Button("Delete \(targets.count) Steps", role: .destructive) {
                store.deleteSteps(listID, targets)
            }
        } else {
            singleMenuItems
        }
    }

    @ViewBuilder
    private var singleMenuItems: some View {
        Button("Edit") {
            select()
            store.editingStepID = step.id
        }
        if level < maxLevels - 1 {
            Button("Break this down further") {
                select()
                breakdowns.start(listID: listID, parentID: step.id, store: store, server: server)
            }
            Button("Add a sub-step") {
                if let id = store.addStep(listID, title: "New step", inside: step.id) {
                    store.selectedStepID = id
                    store.editingStepID = id
                }
            }
        }
        Divider()
        Button("Move up") { store.moveStep(listID, step.id, by: -1) }
        Button("Move down") { store.moveStep(listID, step.id, by: 1) }
        Button("Indent") { store.indent(listID, step.id) }
            .disabled(!store.canIndent(listID, step.id))
        Button("Outdent") { store.outdent(listID, step.id) }
            .disabled(level == 0)
        Divider()
        Button("Delete", role: .destructive) { store.deleteStep(listID, step.id) }
    }

    /// Dragging a selected step takes the whole selection with it.
    private var dragIDs: [UUID] {
        isSelected && store.selectedSet.count > 1 ? Array(store.selectedSet) : [step.id]
    }

    private var dragPayload: String { dragIDs.map(\.uuidString).joined(separator: ",") }

    private func select() {
        store.selectStep(step.id, in: listID, mode: .replace)
        focusSteps()
    }

    private func toggleOpen() {
        let change = { store.setExpanded(listID, step.id, !isOpen) }
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.15)) { change() } }
    }
}

/// Inline editor for title, minutes, note.
struct StepEditor: View {
    let step: Step
    let listID: UUID
    var onFinish: () -> Void
    @Environment(Store.self) private var store
    @State private var title = ""
    @State private var minutes = ""
    @State private var note = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Step", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            HStack(spacing: 8) {
                TextField("min", text: $minutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .onSubmit(save)
                Text("min").font(.caption).foregroundStyle(.secondary)
                TextField("Note (optional)", text: $note)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            HStack {
                Button("Save", action: save).buttonStyle(.borderedProminent).controlSize(.small)
                Button("Cancel", action: cancel).controlSize(.small)
            }
        }
        .onExitCommand(perform: cancel)
        .onAppear {
            title = step.title == "New step" ? "" : step.title
            minutes = step.minutes.map(String.init) ?? ""
            note = step.note ?? ""
            focused = true
        }
    }

    private func save() {
        let m = Int(minutes.filter(\.isNumber))
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.editStep(listID, step.id, title: t.isEmpty ? step.title : t, minutes: m, note: note)
        store.editingStepID = nil
        onFinish()
    }

    private func cancel() {
        store.editingStepID = nil
        onFinish()
    }
}

enum StepDropZone { case before, inside }

/// Drop target for a step row. Reports where in the row the pointer is so the UI can show
/// "insert above" or "make sub-steps", and hands back every dragged step id.
struct StepDropDelegate: DropDelegate {
    var zoneAt: (CGFloat) -> StepDropZone
    var setZone: (StepDropZone?) -> Void
    var perform: ([UUID], StepDropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { setZone(zoneAt(info.location.y)) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        setZone(zoneAt(info.location.y))
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { setZone(nil) }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zoneAt(info.location.y)
        setZone(nil)
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: String.self) { text, _ in
            let ids = (text ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return }
            DispatchQueue.main.async { perform(ids, zone) }
        }
        return true
    }
}
