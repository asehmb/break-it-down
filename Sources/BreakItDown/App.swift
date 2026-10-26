import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (@MainActor () async -> Void)?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Unload the model / stop the server we started before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work = onTerminate, !terminating else { return .terminateNow }
        terminating = true
        Task { @MainActor in
            await work()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Small bits of UI state shared between views and menu commands.
@MainActor
@Observable
final class UIState {
    var showHelp = false
    var showFocus = false
    var focusTaskFieldToken = 0
    var focusNewStepToken = 0
    var didSetup = false
}

@main
struct BreakItDownApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()
    @State private var server = ModelServer()
    @State private var breakdowns = Breakdowns()
    @State private var ui = UIState()

    var body: some Scene {
        Window("Break It Down", id: "main") {
            ContentView()
                .environment(store)
                .environment(server)
                .environment(breakdowns)
                .environment(ui)
                .tint(Palette.accent)
                .frame(minWidth: 380, minHeight: 480)
                .onAppear(perform: setup)
        }
        .defaultSize(width: 1000, height: 720)
        .commands {
            AppCommands(store: store, server: server, breakdowns: breakdowns, ui: ui)
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(server)
                .tint(Palette.accent)
        }
    }

    private func setup() {
        guard !ui.didSetup else { return }
        ui.didSetup = true
        NSApp.appearance = store.settings.theme.appearance
        let store = self.store
        let server = self.server
        // A drag that ends anywhere (cancelled, or dropped between rows) must not leave the drop marker behind.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { event in
            if store.dropTarget != nil { DispatchQueue.main.async { store.dropTarget = nil } }
            return event
        }
        delegate.onTerminate = {
            await server.stop(store.settings, unload: store.settings.unloadOnQuit)
        }
        if store.settings.autoStart {
            server.start(store.settings)
        }
    }
}

struct AppCommands: Commands {
    let store: Store
    let server: ModelServer
    let breakdowns: Breakdowns
    let ui: UIState

    /// While a text field is being edited, Command-Z undoes typing instead of the list change.
    private static func forwardToTextEditor(_ action: String) -> Bool {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable,
              let manager = editor.undoManager,
              action == "undo:" ? manager.canUndo : manager.canRedo else { return false }
        return NSApp.sendAction(Selector(action), to: nil, from: nil)
    }

    private var listID: UUID? { store.selectedListID }
    private var stepID: UUID? { store.selectedStepID }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New List") {
                store.newList()
                ui.focusTaskFieldToken += 1
            }
            .keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import…") { DataTransfer.importData(store) }
                .keyboardShortcut("o")
            Button("Export…") { DataTransfer.exportData(store) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Steps") {
            Button("Break It Down") {
                guard let listID else { return }
                breakdowns.start(listID: listID, parentID: stepID, store: store, server: server)
            }
            .keyboardShortcut("b")
            .disabled(listID == nil)

            Button("Focus Mode") { ui.showFocus = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(listID == nil)

            Divider()

            Button("Add Step") { ui.focusNewStepToken += 1 }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(listID == nil)
            Button("Toggle Done") {
                if let listID, let stepID { store.toggle(listID, stepID) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(stepID == nil)
            Button("Edit Step") { store.editingStepID = stepID }
                .keyboardShortcut("e")
                .disabled(stepID == nil)

            Divider()

            Button("Indent") { if let listID, let stepID { store.indent(listID, stepID) } }
                .keyboardShortcut("]")
                .disabled(stepID == nil)
            Button("Outdent") { if let listID, let stepID { store.outdent(listID, stepID) } }
                .keyboardShortcut("[")
                .disabled(stepID == nil)
            Button("Move Up") { if let listID, let stepID { store.moveStep(listID, stepID, by: -1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(stepID == nil)
            Button("Move Down") { if let listID, let stepID { store.moveStep(listID, stepID, by: 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(stepID == nil)

            Divider()

            Button("Delete Step") { if let listID, let stepID { store.deleteStep(listID, stepID) } }
                .disabled(stepID == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(store.undoActionName.map { "Undo \($0)" } ?? "Undo") {
                if !Self.forwardToTextEditor("undo:") { store.undo() }
            }
            .keyboardShortcut("z")
            Button(store.redoActionName.map { "Redo \($0)" } ?? "Redo") {
                if !Self.forwardToTextEditor("redo:") { store.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { ui.showHelp = true }
                .keyboardShortcut("/")
        }
    }
}

// MARK: - Look

enum Palette {
    /// The one accent color: a calm teal.
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.42, green: 0.78, blue: 0.72, alpha: 1)
        }
        return NSColor(srgbRed: 0.13, green: 0.47, blue: 0.44, alpha: 1)
    })
    static let card = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(white: 1, alpha: 0.05)
        }
        return NSColor(white: 0, alpha: 0.035)
    })
}

// MARK: - Import / export

enum DataTransfer {
    @MainActor
    static func exportData(_ store: Store) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "break-it-down-\(f.string(from: Date())).json"
        guard panel.runModal() == .OK, let url = panel.url, let bytes = store.exportJSON() else { return }
        do { try bytes.write(to: url, options: .atomic) } catch {
            alert("Couldn't export", error.localizedDescription)
        }
    }

    @MainActor
    static func importData(_ store: Store) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importJSON(try Data(contentsOf: url))
        } catch let e as FriendlyError {
            alert(e.title, e.detail)
        } catch {
            alert("Couldn't import that file", "It doesn't look like a Break It Down export. (\(error.localizedDescription))")
        }
    }

    @MainActor
    static func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
