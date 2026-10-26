import SwiftUI
import AppKit

enum DetailField: Hashable {
    case title, task, context, newStep, steps
}

struct ListDetailView: View {
    let listID: UUID
    @Environment(Store.self) private var store
    @Environment(ModelServer.self) private var server
    @Environment(Breakdowns.self) private var breakdowns
    @Environment(UIState.self) private var ui
    @FocusState private var focus: DetailField?
    @State private var newStepText = ""

    var body: some View {
        if let list = store.list(listID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(list)
                    breakdownBox(list)
                    stepsSection(list)
                }
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 90)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(list.title.isEmpty ? "Untitled task" : list.title)
            .onAppear {
                if list.steps.isEmpty { focus = .task }
            }
            .onChange(of: ui.focusTaskFieldToken) { _, _ in focus = .task }
            .onChange(of: ui.focusNewStepToken) { _, _ in focus = .newStep }
            .onChange(of: store.selectedStepID) { _, new in
                if new != nil && focus == nil { focus = .steps }
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ list: TaskList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Untitled task", text: Binding(
                get: { list.title },
                set: { v in store.updateList(listID) { $0.title = v } }),
                axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(1...4)
                .padding(.vertical, 4)
                .fixedSize(horizontal: false, vertical: true)
                .focused($focus, equals: .title)
                .onSubmit { focus = .steps }

            if list.totalLeaves > 0 {
                HStack(spacing: 14) {
                    ProgressView(value: list.progress)
                        .progressViewStyle(.linear)
                        .tint(Palette.accent)
                        .frame(maxWidth: 260)
                    Text("\(list.doneLeaves) of \(list.totalLeaves) steps done")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        ui.showFocus = true
                    } label: {
                        Label("Focus", systemImage: "scope")
                    }
                    .controlSize(.large)
                    .help("Show only the next step (F)")
                }
            }
        }
    }

    // MARK: Break it down

    @ViewBuilder
    private func breakdownBox(_ list: TaskList) -> some View {
        let session = breakdowns.session(listID)
        let loading = breakdowns.isLoading(listID)
        VStack(alignment: .leading, spacing: 12) {
            TextField("What do you need to do?", text: Binding(
                get: { list.breakdownText },
                set: { v in store.updateList(listID) { $0.breakdownText = v } }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.title3)
                .lineLimit(1...4)
                .focused($focus, equals: .task)
                .onSubmit(startBreakdown)
            Divider()
            TextField("Anything that helps? e.g. “due Friday”, “I've never used Figma”", text: Binding(
                get: { list.context },
                set: { v in store.updateList(listID) { $0.context = v } }), axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
                .focused($focus, equals: .context)
                .onSubmit(startBreakdown)
            HStack(spacing: 12) {
                Button(action: startBreakdown) {
                    Label("Break it down", systemImage: "wand.and.stars")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(loading || effectiveTask(list).isEmpty)
                .help("Break it down (B)")

                if loading, case .loading(let msg)? = session?.phase {
                    ProgressView().controlSize(.small)
                    Text(msg).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel") { breakdowns.cancel(listID) }
                }
                Spacer(minLength: 0)
            }
            if let session, !loading {
                BreakdownSessionView(key: listID, session: session, onAddByHand: {
                    breakdowns.dismiss(listID)
                    focus = .newStep
                })
                .padding(.top, 4)
            }
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func effectiveTask(_ list: TaskList) -> String {
        let t = list.breakdownText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? list.title.trimmingCharacters(in: .whitespacesAndNewlines) : t
    }

    private func startBreakdown() {
        guard let list = store.list(listID), !effectiveTask(list).isEmpty, !breakdowns.isLoading(listID) else { return }
        if list.title.trimmingCharacters(in: .whitespaces).isEmpty {
            let t = effectiveTask(list)
            store.updateList(listID) { $0.title = t.count > 60 ? String(t.prefix(60)) + "…" : t }
        }
        breakdowns.start(listID: listID, parentID: nil, store: store, server: server)
    }

    // MARK: Steps

    @ViewBuilder
    private func stepsSection(_ list: TaskList) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if list.steps.isEmpty {
                Text("No steps yet. Describe the task above and press Break it down, or add a step yourself below.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(list.steps) { step in
                StepNode(step: step, list: list, level: 0, focusSteps: { focus = .steps })
            }
            addStepRow(list)
        }
        .focusable()
        .focused($focus, equals: .steps)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .dropDestination(for: String.self) { items, _ in
            store.dropTarget = nil
            let ids = items.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) }
            guard !ids.isEmpty else { return false }
            store.moveSteps(listID, ids, to: .end)
            return true
        }
    }

    @ViewBuilder
    private func addStepRow(_ list: TaskList) -> some View {
        let after = store.selectedStepID.flatMap { list.steps.step(withID: $0) }
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.leading, 30)
            TextField(after.map { "Add a step after “\($0.title)”" } ?? "Add a step", text: $newStepText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($focus, equals: .newStep)
                // Pasting several lines makes one step per line.
                .onChange(of: newStepText) { _, text in
                    guard text.contains(where: \.isNewline) else { return }
                    if let id = store.addSteps(fromLines: text, listID, after: store.selectedStepID) {
                        store.selectedStepID = id
                    }
                    newStepText = ""
                }
                .onSubmit {
                    if let id = store.addStep(listID, title: newStepText, after: store.selectedStepID) {
                        store.selectedStepID = id
                    }
                    newStepText = ""
                    focus = .newStep
                }
                .onExitCommand {
                    newStepText = ""
                    focus = .steps
                }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
    }

    // MARK: Keys

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let mods = press.modifiers
        if mods.contains(.command) || mods.contains(.control) { return .ignored }
        let sel = store.selectedStepID

        switch press.key {
        case .upArrow:
            if mods.contains(.option), let sel { store.moveStep(listID, sel, by: -1) } else { store.moveSelection(listID, by: -1) }
            return .handled
        case .downArrow:
            if mods.contains(.option), let sel { store.moveStep(listID, sel, by: 1) } else { store.moveSelection(listID, by: 1) }
            return .handled
        case .leftArrow:
            if let sel { store.setExpanded(listID, sel, false) }
            return .handled
        case .rightArrow:
            if let sel { store.setExpanded(listID, sel, true) }
            return .handled
        case .space:
            if let sel { store.toggle(listID, sel) }
            return .handled
        case .return:
            focus = .newStep
            return .handled
        case .tab:
            if let sel {
                if mods.contains(.shift) { store.outdent(listID, sel) } else { store.indent(listID, sel) }
            }
            return .handled
        case .escape:
            if store.editingStepID != nil { store.editingStepID = nil }
            else if ui.showHelp { ui.showHelp = false }
            else if !store.extraSelectedIDs.isEmpty { store.extraSelectedIDs = [] }
            else { store.selectedStepID = nil }
            return .handled
        case .delete, .deleteForward:
            let all = store.selectedSet
            if all.count > 1 { store.deleteSteps(listID, all) }
            else if let sel { store.deleteStep(listID, sel) }
            return .handled
        default:
            break
        }

        switch press.characters {
        case "\u{19}": // Shift-Tab arrives as back-tab on some keyboards
            if let sel { store.outdent(listID, sel) }
            return .handled
        case "n", "N":
            store.newList()
            ui.focusTaskFieldToken += 1
            return .handled
        case "f", "F":
            ui.showFocus = true
            return .handled
        case "b", "B":
            if let sel, store.level(of: sel, in: listID) < maxLevels - 1 {
                breakdowns.start(listID: listID, parentID: sel, store: store, server: server)
            } else {
                startBreakdown()
            }
            return .handled
        case "e", "E":
            if let sel { store.editingStepID = sel }
            return .handled
        case "?", "/":
            ui.showHelp = true
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Draft / error panel

struct BreakdownSessionView: View {
    let key: UUID
    let session: Breakdowns.Session
    var onAddByHand: () -> Void
    @Environment(Store.self) private var store
    @Environment(ModelServer.self) private var server
    @Environment(Breakdowns.self) private var breakdowns

    var body: some View {
        switch session.phase {
        case .loading(let msg):
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(msg).foregroundStyle(.secondary)
                Button("Cancel") { breakdowns.cancel(key) }
            }
            .padding(.vertical, 6)
        case .failed(let err):
            ErrorCard(error: err,
                      retry: { breakdowns.regenerate(key, store: store, server: server) },
                      secondaryTitle: "Add steps by hand",
                      secondary: onAddByHand)
            .padding(14)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        case .draft(let steps):
            draft(steps)
        }
    }

    @ViewBuilder
    private func draft(_ steps: [DraftStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Draft").font(.headline)
                Text("Nothing is added until you accept.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if steps.isEmpty {
                Text("You removed every step. Regenerate, or discard this draft.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { idx, s in
                    draftRow(s, number: idx + 1)
                    ForEach(s.substeps) { sub in
                        draftRow(sub, number: nil)
                            .padding(.leading, 30)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("Accept all") { breakdowns.accept(key, store: store) }
                    .buttonStyle(.borderedProminent)
                    .disabled(steps.isEmpty)
                Button("Regenerate") { breakdowns.regenerate(key, store: store, server: server) }
                Button("Discard") { breakdowns.dismiss(key) }
            }
            .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Palette.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private func draftRow(_ s: DraftStep, number: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let number {
                Text("\(number).").foregroundStyle(.secondary).monospacedDigit().frame(width: 22, alignment: .trailing)
            } else {
                Text("–").foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
            }
            Text(s.title)
                .font(number == nil ? .callout : .body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let m = s.minutes {
                Text("\(m) min").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                breakdowns.removeDraftStep(key, s.id)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove from draft")
            .accessibilityLabel("Remove \(s.title)")
        }
    }
}
