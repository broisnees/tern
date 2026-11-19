import MailEngine
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "at") }
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 620, height: 460)
    }
}

@MainActor
private struct GeneralSettings: View {
    @AppStorage(SettingsKey.checkInterval) private var interval = 5
    @AppStorage(SettingsKey.notifyNewMail) private var notify = true
    @AppStorage(SettingsKey.loadRemoteImages) private var loadImages = false

    var body: some View {
        Form {
            Picker("Check for new mail", selection: $interval) {
                Text("Every minute").tag(1)
                Text("Every 2 minutes").tag(2)
                Text("Every 5 minutes").tag(5)
                Text("Every 15 minutes").tag(15)
                Text("Every 30 minutes").tag(30)
            }
            Toggle("Notify me about new mail", isOn: $notify)
            Toggle(isOn: $loadImages) {
                Text("Load images from the web")
                Text("Off keeps senders from seeing when you open their email. Each message still has a Load images button.")
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: UUID?
    @State private var showAdd = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(model.accounts) { account in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.accountColor(account.colorIndex))
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.email).lineLimit(1)
                                Text(account.provider?.name ?? "IMAP")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(account.id)
                    }
                }
                .listStyle(.bordered)
                HStack {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Add account")
                    .help("Add account")
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .frame(width: 220)
            .padding([.leading, .vertical], 16)

            Group {
                if let id = selectedID, let account = model.account(id) {
                    AccountDetail(account: account)
                        .id(account.id)
                } else {
                    ContentUnavailableView {
                        Label(model.accounts.isEmpty ? "No accounts yet" : "No account selected", systemImage: "at")
                    } description: {
                        Text(model.accounts.isEmpty ? "Add an account to start reading mail." : "Pick an account to change its name, signature or password.")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { selectedID = selectedID ?? model.accounts.first?.id }
        .sheet(isPresented: $showAdd) {
            AddAccountView()
                .environment(model)
        }
    }
}

@MainActor
private struct AccountDetail: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    @State private var senderName: String
    @State private var signature: String
    @State private var newPassword = ""
    @State private var passwordStatus: String?
    @State private var confirmRemove = false

    init(account: AccountConfig) {
        self.account = account
        _senderName = State(initialValue: account.senderName)
        _signature = State(initialValue: account.signature)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Email", value: account.email)
                TextField("Your name", text: $senderName)
                    .onSubmit(save)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Signature")
                    TextEditor(text: $signature)
                        .font(.body)
                        .frame(minHeight: 60)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Section("Password") {
                HStack {
                    SecureField("New app password", text: $newPassword)
                    Button("Update") {
                        model.updatePassword(newPassword, for: account.id)
                        newPassword = ""
                        passwordStatus = "Password updated. Tern is reconnecting."
                    }
                    .disabled(newPassword.isEmpty)
                }
                if let passwordStatus {
                    Text(passwordStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Servers") {
                LabeledContent("Incoming", value: "\(account.imap.host):\(account.imap.port)")
                LabeledContent("Outgoing", value: "\(account.smtp.host):\(account.smtp.port)")
                LabeledContent("User name", value: account.imap.username)
            }
            Section {
                Button("Remove account…", role: .destructive) { confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .onChange(of: signature) { _, _ in save() }
        .onChange(of: senderName) { _, _ in save() }
        .confirmationDialog("Remove \(account.email)?", isPresented: $confirmRemove) {
            Button("Remove account", role: .destructive) { model.removeAccount(account.id) }
        } message: {
            Text("Tern deletes its downloaded copy and the saved password. Your mail stays on the server.")
        }
    }

    private func save() {
        var updated = account
        updated.senderName = senderName.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.signature = signature
        guard updated != account else { return }
        model.updateAccount(updated)
    }
}

@MainActor
private struct ShortcutsSettings: View {
    private let rows: [(String, String)] = [
        ("New message", "⌘N   or   C"),
        ("Send", "⌘↩"),
        ("Reply", "⌘R   or   R"),
        ("Reply all", "⇧⌘R   or   A"),
        ("Forward", "⇧⌘F   or   F"),
        ("Archive", "⌃⌘A   or   E"),
        ("Move to Trash", "⌘⌫   or   #"),
        ("Mark as spam", "⇧⌘J   or   !"),
        ("Mark as read or unread", "⇧⌘U   or   U"),
        ("Star", "⇧⌘L   or   S"),
        ("Next or previous message", "↓ ↑   or   J K"),
        ("Search the server", "Type a search, then Return"),
        ("Get new mail", "⇧⌘N"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(rows, id: \.0) { row in
                    LabeledContent(row.0) {
                        Text(row.1)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Single-letter shortcuts work while the message list is focused.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
