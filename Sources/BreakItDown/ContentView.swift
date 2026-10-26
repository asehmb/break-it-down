import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui

    var body: some View {
        @Bindable var ui = ui
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            if let id = store.selectedListID, store.list(id) != nil {
                ListDetailView(listID: id)
                    .id(id)
            } else {
                EmptyStateView()
            }
        }
        .overlay(alignment: .bottom) { UndoToast() }
        .sheet(isPresented: $ui.showHelp) { HelpSheet() }
        .sheet(isPresented: $ui.showFocus) {
            if let id = store.selectedListID {
                FocusModeView(listID: id)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ThemeMenu()
                Button { ui.showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .help("Keyboard shortcuts (?)")
            }
        }
        .onChange(of: store.settings.theme) { _, theme in
            NSApp.appearance = theme.appearance
        }
    }
}

struct ThemeMenu: View {
    @Environment(Store.self) private var store
    var body: some View {
        Menu {
            ForEach(Theme.allCases) { t in
                Button {
                    store.settings.theme = t
                } label: {
                    if store.settings.theme == t { Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                }
            }
        } label: {
            Image(systemName: store.settings.theme == .dark ? "moon" : store.settings.theme == .light ? "sun.max" : "circle.lefthalf.filled")
        }
        .help("Theme")
    }
}

struct EmptyStateView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 40))
                .foregroundStyle(Palette.accent)
            Text("Pick a task on the left, or start a new one.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("New task") {
                store.newList()
                ui.focusTaskFieldToken += 1
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct UndoToast: View {
    @Environment(Store.self) private var store
    var body: some View {
        if let label = store.undoToast {
            HStack(spacing: 14) {
                Text(label)
                    .lineLimit(1)
                Button("Undo") { store.undo() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button {
                    store.undoToast = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.bottom, 20)
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(Store.self) private var store
    @Environment(UIState.self) private var ui
    @State private var pendingDelete: TaskList?

    var body: some View {
        let selection = Binding<UUID?>(
            get: { store.selectedListID },
            set: { new in
                if new != store.selectedListID {
                    store.selectedListID = new
                    store.selectedStepID = nil
                    store.editingStepID = nil
                }
            })
        List(selection: selection) {
            ForEach(store.data.lists) { list in
                SidebarRow(list: list)
                    .tag(list.id)
                    .contextMenu {
                        Button("Rename") { store.renamingListID = list.id }
                        Button("Move Up") { store.moveList(list.id, by: -1) }
                        Button("Move Down") { store.moveList(list.id, by: 1) }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = list }
                    }
            }
            .onMove { store.moveLists(from: $0, to: $1) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    store.newList()
                    ui.focusTaskFieldToken += 1
                } label: {
                    Label("New task", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("New list (N)")
                Divider()
                ModelStatusView()
            }
            .padding(12)
            .background(.bar)
        }
        .onDeleteCommand {
            if let id = store.selectedListID, let l = store.list(id) { pendingDelete = l }
        }
        .confirmationDialog(
            "Delete this list?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { l in
            Button("Delete “\(l.title.isEmpty ? "Untitled task" : l.title)”", role: .destructive) {
                store.deleteList(l.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("All of its steps go too. You can undo right after.")
        }
    }
}

struct SidebarRow: View {
    let list: TaskList
    @Environment(Store.self) private var store
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.renamingListID == list.id {
                TextField("Task name", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($editing)
                    .onAppear {
                        text = list.title
                        editing = true
                    }
                    .onSubmit(commit)
                    .onExitCommand { store.renamingListID = nil }
                    .onChange(of: editing) { _, now in if !now { commit() } }
            } else {
                HStack(spacing: 6) {
                    Text(list.title.isEmpty ? "Untitled task" : list.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(list.title.isEmpty ? .secondary : .primary)
                    if list.isExample {
                        Text("Example")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(Palette.accent)
                    }
                }
            }
            if list.totalLeaves > 0 {
                ProgressView(value: list.progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
                Text("\(list.doneLeaves) of \(list.totalLeaves) steps done")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No steps yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func commit() {
        guard store.renamingListID == list.id else { return }
        store.renameList(list.id, to: text)
        store.renamingListID = nil
    }
}

struct ModelStatusView: View {
    @Environment(Store.self) private var store
    @Environment(ModelServer.self) private var server
    @State private var showDetails = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            switch server.status {
            case .ready:
                Circle().fill(Palette.accent).frame(width: 8, height: 8)
                Text("\(shortName) ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            case .starting(let msg):
                ProgressView().controlSize(.small)
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            case .idle:
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
                Text("Model stopped")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Start model") { server.start(store.settings) }
                    .controlSize(.small)
            case .failed(let err):
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Button {
                    showDetails = true
                } label: {
                    Text(err.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDetails) {
                    ErrorCard(error: err, retryTitle: "Start model", retry: {
                        showDetails = false
                        server.start(store.settings)
                    })
                    .frame(width: 360)
                    .padding()
                }
                Spacer(minLength: 4)
                Button("Start model") { server.start(store.settings) }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortName: String {
        let n = store.settings.modelDisplayName
        if store.settings.engine == .apple { return "Apple model" }
        if n.lowercased().contains("gemma-4") { return "Gemma 4" }
        return n
    }
}

/// Plain-language error, with the exact fix shown in a copyable box.
struct ErrorCard: View {
    let error: FriendlyError
    var retryTitle: String = "Try again"
    var retry: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondary: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(error.title, systemImage: "exclamationmark.bubble")
                .font(.headline)
            if !error.detail.isEmpty {
                Text(error.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if let fix = error.fix {
                HStack(alignment: .top, spacing: 8) {
                    Text("Fix:").font(.callout.weight(.semibold))
                    Text(fix)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.command(in: fix), forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                if let retry { Button(retryTitle, action: retry).buttonStyle(.borderedProminent) }
                if let secondaryTitle, let secondary { Button(secondaryTitle, action: secondary) }
            }
        }
    }

    /// Copy just the Terminal command if the fix contains one.
    static func command(in fix: String) -> String {
        for marker in ["Terminal: ", "Terminal:"] {
            if let r = fix.range(of: marker) { return String(fix[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return fix
    }
}

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let rows: [(String, String)] = [
        ("N", "New list"),
        ("B", "Break it down (or break the selected step down further)"),
        ("F", "Focus mode"),
        ("Enter", "Add a step"),
        ("E", "Edit the selected step"),
        ("Space", "Check / uncheck the selected step"),
        ("Tab / Shift-Tab", "Indent / outdent"),
        ("↑ / ↓", "Select previous / next step"),
        ("⌥↑ / ⌥↓", "Move the step up / down"),
        ("← / →", "Collapse / expand"),
        ("Delete", "Delete the selected step (Command-Z undoes it)"),
        ("Esc", "Close panels, stop editing"),
        ("?", "This cheat sheet"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard shortcuts").font(.title2.weight(.semibold))
            Text("Single keys work when the step list has focus (click a step first). Menu versions with ⌘ work anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0)
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.card, in: RoundedRectangle(cornerRadius: 6))
                        Text(row.1)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}
