import MailEngine
import SwiftUI

@MainActor
struct MessageListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        let messages = model.visibleMessages
        List(selection: $model.selectedMessageIDs) {
            ForEach(messages) { message in
                MessageRow(message: message, showAccount: model.isUnifiedView)
                    .tag(message.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button {
                            model.toggleRead([message.id])
                        } label: {
                            Label(message.isSeen ? "Mark unread" : "Mark read",
                                  systemImage: message.isSeen ? "envelope.badge" : "envelope.open")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            model.trash([message.id])
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        Button {
                            model.archive([message.id])
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                        }
                        .tint(.indigo)
                    }
            }
            if model.canLoadOlder {
                HStack {
                    Spacer()
                    if model.isLoadingOlder {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Loading older messages")
                    } else {
                        Button("Load older messages") { model.loadOlder() }
                            .buttonStyle(.link)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .selectionDisabled()
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            MessageActionsMenu(ids: ids)
        }
        .overlay {
            if messages.isEmpty {
                emptyState
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search mail")
        .onSubmit(of: .search) { model.searchOnServer() }
        .navigationTitle(model.selectionTitle)
        .navigationSubtitle(model.selectionSubtitle)
        .safeAreaInset(edge: .top, spacing: 0) { searchStatus }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let banner = model.banner {
                BannerView(banner: banner) { model.banner = nil }
            }
        }
        .onKeyPress(phases: .down) { press in handleKey(press, messages: messages) }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    openWindow(id: "compose", value: model.newDraft())
                } label: {
                    Label("New message", systemImage: "square.and.pencil")
                }
                .help("New message (⌘N)")
                Button {
                    model.refreshAll()
                } label: {
                    Label("Get new mail", systemImage: "arrow.clockwise")
                }
                .help("Get new mail (⇧⌘N)")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoadingSelection {
            ProgressView("Loading messages…")
        } else if model.isSearchingServer {
            ProgressView("Searching the server…")
        } else if !model.searchText.isEmpty {
            ContentUnavailableView {
                Label("No matches for \"\(model.searchText)\"", systemImage: "magnifyingglass")
            } description: {
                Text(model.serverResults == nil
                     ? "Only downloaded mail was searched. Press Return to search everything on the server."
                     : "The server found nothing either. Try fewer or different words.")
            }
        } else {
            ContentUnavailableView {
                Label("No messages", systemImage: "tray")
            } description: {
                Text("New mail shows up here. Tern checks every few minutes.")
            }
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if model.serverResults != nil || model.isSearchingServer {
            HStack(spacing: 8) {
                if model.isSearchingServer {
                    ProgressView().controlSize(.small)
                    Text("Searching the server…")
                } else {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    Text("\(model.serverResults?.count ?? 0) results from the server")
                }
                Spacer()
                Button("Show downloaded mail") { model.clearServerSearch() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// Gmail-style single-key shortcuts while the list has focus.
    private func handleKey(_ press: KeyPress, messages: [MessageSummary]) -> KeyPress.Result {
        guard press.modifiers.isEmpty || press.modifiers == .shift else { return .ignored }
        let ids = model.selectedMessageIDs
        switch press.characters {
        case "j", "k":
            guard !messages.isEmpty else { return .ignored }
            let current = messages.firstIndex { ids.contains($0.id) }
            let next: Int
            if let current {
                next = press.characters == "j" ? min(current + 1, messages.count - 1) : max(current - 1, 0)
            } else {
                next = 0
            }
            model.selectedMessageIDs = [messages[next].id]
            return .handled
        case "e":
            guard !ids.isEmpty else { return .ignored }
            model.archive(ids)
            return .handled
        case "#":
            guard !ids.isEmpty else { return .ignored }
            model.trash(ids)
            return .handled
        case "s":
            guard !ids.isEmpty else { return .ignored }
            model.toggleFlag(ids)
            return .handled
        case "u":
            guard !ids.isEmpty else { return .ignored }
            model.toggleRead(ids)
            return .handled
        case "!":
            guard !ids.isEmpty else { return .ignored }
            model.markSpam(ids)
            return .handled
        case "c":
            openWindow(id: "compose", value: model.newDraft())
            return .handled
        case "r", "a", "f":
            guard ids.count == 1, let message = model.message(id: ids.first!) else { return .ignored }
            let mode: ReplyMode = press.characters == "r" ? .reply : press.characters == "a" ? .replyAll : .forward
            openWindow(id: "compose", value: model.replyDraft(mode, to: message))
            return .handled
        default:
            return .ignored
        }
    }
}

@MainActor
struct MessageRow: View {
    @Environment(AppModel.self) private var model
    let message: MessageSummary
    let showAccount: Bool

    private var isSentMail: Bool {
        model.mailbox(id: message.mailboxID)?.role == .sent
    }

    private var senderLine: String {
        if isSentMail {
            let names = message.to.map { $0.name ?? $0.address }
            return "To: " + (names.isEmpty ? "(no recipients)" : names.joined(separator: ", "))
        }
        return message.senderDisplay
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(message.isSeen ? Color.clear : Theme.brand)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(senderLine)
                        .font(.body.weight(message.isSeen ? .regular : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Has attachments")
                    }
                    if message.isFlagged {
                        Image(systemName: "star.fill")
                            .imageScale(.small)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Starred")
                    }
                    Text(DateText.short(message.date))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(message.subjectDisplay)
                    .font(.callout.weight(message.isSeen ? .regular : .medium))
                    .lineLimit(1)
                Text(message.snippet ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                if showAccount, let account = model.account(message.accountID) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.accountColor(account.colorIndex))
                            .frame(width: 6, height: 6)
                        Text(account.email)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityValue(message.isSeen ? "" : "Unread")
    }
}

/// Shared by the list's context menu and the reader toolbar's "More" menu.
@MainActor
struct MessageActionsMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let ids: Set<String>

    var body: some View {
        let messages = ids.compactMap(model.message(id:))
        if messages.count == 1, let message = messages.first {
            Button("Reply") { openWindow(id: "compose", value: model.replyDraft(.reply, to: message)) }
            Button("Reply All") { openWindow(id: "compose", value: model.replyDraft(.replyAll, to: message)) }
            Button("Forward") { openWindow(id: "compose", value: model.replyDraft(.forward, to: message)) }
            Divider()
        }
        if !messages.isEmpty {
            Button(messages.contains { !$0.isSeen } ? "Mark as Read" : "Mark as Unread") { model.toggleRead(ids) }
            Button(messages.contains { !$0.isFlagged } ? "Star" : "Remove Star") { model.toggleFlag(ids) }
            Divider()
            Button("Archive") { model.archive(ids) }
            Button("Mark as Spam") { model.markSpam(ids) }
            MoveMenu(ids: ids)
            Divider()
            Button("Move to Trash", role: .destructive) { model.trash(ids) }
        }
    }
}

@MainActor
struct MoveMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<String>
    var asSubmenu = true

    var body: some View {
        let messages = ids.compactMap(model.message(id:))
        let accountIDs = Set(messages.map(\.accountID))
        // Moving only works inside one account.
        if accountIDs.count == 1, let accountID = accountIDs.first {
            let current = Set(messages.map(\.mailboxID))
            let targets = (model.mailboxes[accountID] ?? []).filter { !current.contains($0.id) }
            if asSubmenu {
                Menu("Move to") { buttons(targets) }
            } else {
                buttons(targets)
            }
        } else if !asSubmenu {
            Text("Select messages from one account to move them")
        }
    }

    @ViewBuilder
    private func buttons(_ targets: [MailboxInfo]) -> some View {
        ForEach(targets) { box in
            Button {
                model.move(ids, to: box)
            } label: {
                Label(box.displayName, systemImage: box.role.symbol)
            }
        }
    }
}
