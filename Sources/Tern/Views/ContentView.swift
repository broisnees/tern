import MailEngine
import SwiftUI

@MainActor
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var started = false

    var body: some View {
        @Bindable var model = model
        Group {
            if model.accounts.isEmpty {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } content: {
                    MessageListView()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 560)
                } detail: {
                    ReaderView()
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $model.isAddingAccount) {
            AddAccountView()
                .environment(model)
        }
        .focusedSceneValue(\.isMainWindow, true)
        .onOpenURL { url in
            if let draft = Self.draft(fromMailto: url, model: model) {
                openWindow(id: "compose", value: draft)
            }
        }
        .task {
            guard !started else { return }
            started = true
            model.start()
        }
    }

    /// `mailto:jane@example.com?subject=Hi&cc=bob@example.com&body=...`
    static func draft(fromMailto url: URL, model: AppModel) -> ComposeDraft? {
        guard url.scheme?.lowercased() == "mailto",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var draft = model.newDraft(to: components.path.removingPercentEncoding ?? components.path)
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "subject": draft.subject = value
            case "cc": draft.cc = value
            case "bcc": draft.bcc = value
            case "body": draft.body = value + draft.body
            case "to": draft.to = [draft.to, value].filter { !$0.isEmpty }.joined(separator: ", ")
            default: break
            }
        }
        return draft
    }
}

@MainActor
struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "envelope.open")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.brand)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Add your first email account")
                    .font(.title.weight(.semibold))
                Text("Tern reads and sends mail from Gmail, iCloud, Zoho, Yahoo, Fastmail and any other IMAP account, all in one inbox.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button {
                model.isAddingAccount = true
            } label: {
                Text("Add account")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("Your password stays in the macOS keychain on this Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
