import AppKit
import MailEngine
import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Tern", id: "main") {
            ContentView()
                .environment(model)
                .tint(Theme.brand)
        }
        .defaultSize(width: 1280, height: 800)
        .handlesExternalEvents(matching: ["mailto"])
        .commands { MailCommands(model: model) }

        WindowGroup("New Message", id: "compose", for: ComposeDraft.self) { $draft in
            ComposeView(draft: draft ?? model.newDraft())
                .environment(model)
                .tint(Theme.brand)
        }
        .defaultSize(width: 680, height: 600)
        .handlesExternalEvents(matching: [])

        Settings {
            SettingsView()
                .environment(model)
                .tint(Theme.brand)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` starts a bare executable; make it behave like a normal app.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@MainActor
struct MailCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.isMainWindow) private var isMainWindow

    private var mailWindowActive: Bool { isMainWindow == true }

    private func act(_ action: (Set<String>) -> Void) {
        guard mailWindowActive, !KeyFocus.isEditingText, !model.selectedMessageIDs.isEmpty else { return }
        action(model.selectedMessageIDs)
    }

    private func reply(_ mode: ReplyMode) {
        guard mailWindowActive, let message = model.selectedMessages.first, model.selectedMessageIDs.count == 1 else { return }
        openWindow(id: "compose", value: model.replyDraft(mode, to: message))
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { openWindow(id: "compose", value: model.newDraft()) }
                .keyboardShortcut("n")
            Button("Add Account…") {
                openWindow(id: "main")
                model.isAddingAccount = true
            }
        }
        CommandMenu("Message") {
            Button("Reply") { reply(.reply) }
                .keyboardShortcut("r")
            Button("Reply All") { reply(.replyAll) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { reply(.forward) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { act(model.archive) }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Move to Trash") { act(model.trash) }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Mark as Spam") { act(model.markSpam) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Mark as Read or Unread") { act(model.toggleRead) }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Star or Unstar") { act(model.toggleFlag) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Get New Mail") { model.refreshAll() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
