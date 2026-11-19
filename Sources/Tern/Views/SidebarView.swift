import MailEngine
import SwiftUI

@MainActor
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Mailboxes") {
                SidebarRow(
                    title: model.accounts.count > 1 ? "All Inboxes" : "Inbox",
                    symbol: model.accounts.count > 1 ? "tray.2" : "tray",
                    unread: model.totalInboxUnread
                )
                .tag(SidebarItem.allInboxes)
                SidebarRow(title: "Starred", symbol: "star", unread: 0)
                    .tag(SidebarItem.starred)
            }

            ForEach(model.accounts) { account in
                Section(isExpanded: expansion(for: account.id)) {
                    let boxes = (model.mailboxes[account.id] ?? []).filter { box in
                        // With one account, its inbox is already the first row above.
                        !(model.accounts.count == 1 && box.role == .inbox)
                    }
                    if boxes.isEmpty, model.status[account.id] == .syncing {
                        Text("Loading folders…")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(boxes) { box in
                        SidebarRow(title: box.displayName, symbol: box.role.symbol,
                                   unread: box.role.showsUnreadBadge ? box.unread : 0)
                            .padding(.leading, CGFloat(box.depth) * 12)
                            .tag(SidebarItem.mailbox(box.id))
                    }
                } header: {
                    AccountHeader(account: account)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button {
                    model.isAddingAccount = true
                } label: {
                    Label("Add account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add another email account")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func expansion(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !collapsed.contains(id) },
            set: { expanded in
                if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            }
        )
    }
}

@MainActor
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let unread: Int

    var body: some View {
        Label(title, systemImage: symbol)
            .badge(unread)
            .lineLimit(1)
    }
}

@MainActor
private struct AccountHeader: View {
    @Environment(AppModel.self) private var model
    let account: AccountConfig
    @State private var confirmRemove = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.accountColor(account.colorIndex))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(account.email)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            switch model.status[account.id] ?? .idle {
            case .syncing:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Checking for mail")
            case .failed(let message):
                Button {
                    model.refresh(accountID: account.id)
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .help("\(message) Click to try again.")
                .accessibilityLabel("Connection problem. \(message) Try again.")
            case .idle:
                EmptyView()
            }
        }
        .contextMenu {
            Button("Check for New Mail") { model.refresh(accountID: account.id) }
            Divider()
            Button("Remove Account…", role: .destructive) { confirmRemove = true }
        }
        .confirmationDialog("Remove \(account.email)?", isPresented: $confirmRemove) {
            Button("Remove account", role: .destructive) { model.removeAccount(account.id) }
        } message: {
            Text("Tern deletes its downloaded copy and the saved password. Your mail stays on the server.")
        }
    }
}
