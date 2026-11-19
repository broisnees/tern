import AppKit
import Foundation
import MailEngine
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case allInboxes
    case starred
    case mailbox(String)
}

enum AccountStatus: Equatable {
    case idle
    case syncing
    case failed(String)
}

enum ReaderState {
    case empty
    case multiple(Int)
    case loading(MessageSummary)
    case loaded(MessageSummary, ParsedMessage)
    case failed(MessageSummary, String)
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

enum SettingsKey {
    static let checkInterval = "checkIntervalMinutes"
    static let loadRemoteImages = "loadRemoteImages"
    static let notifyNewMail = "notifyNewMail"
}

@MainActor
@Observable
final class AppModel {
    // MARK: State the views read

    private(set) var accounts: [AccountConfig] = []
    private(set) var mailboxes: [UUID: [MailboxInfo]] = [:]
    private(set) var snapshots: [String: MailboxSnapshot] = [:]
    private(set) var status: [UUID: AccountStatus] = [:]
    /// Mailboxes on their first sync, with nothing cached to show yet.
    private(set) var loadingMailboxes: Set<String> = []
    private(set) var loadingOlder: Set<String> = []

    var selection: SidebarItem? = .allInboxes {
        didSet {
            guard oldValue != selection else { return }
            selectedMessageIDs = []
            clearServerSearch()
            refreshSelection()
        }
    }

    var selectedMessageIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedMessageIDs else { return }
            openSelectedMessage()
        }
    }

    var searchText = "" {
        didSet { if searchText.isEmpty { clearServerSearch() } }
    }

    private(set) var serverResults: [MessageSummary]?
    private(set) var isSearchingServer = false
    private(set) var reader: ReaderState = .empty
    /// Message ids whose remote images the person chose to load.
    var remoteImagesAllowed: Set<String> = []
    var banner: Banner?
    var isAddingAccount = false

    // MARK: Private

    private let store = Persistence()
    private var sessions: [UUID: AccountSession] = [:]
    private var pollTask: Task<Void, Never>?
    private var readerTask: Task<Void, Never>?
    private var bannerTask: Task<Void, Never>?
    private var prefetching: Set<String> = []

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.checkInterval: 5,
            SettingsKey.loadRemoteImages: false,
            SettingsKey.notifyNewMail: true,
        ])
        accounts = store.loadAccounts()
        for account in accounts {
            mailboxes[account.id] = store.loadMailboxes(accountID: account.id)
            for box in mailboxes[account.id] ?? [] where box.role == .inbox {
                snapshots[box.id] = store.loadSnapshot(accountID: account.id, path: box.path)
            }
            makeSession(for: account)
        }
    }

    func start() {
        Notifier.requestAuthorization()
        updateBadge()
        refreshAll()
        schedulePolling()
    }

    // MARK: Lookups

    func account(_ id: UUID) -> AccountConfig? { accounts.first { $0.id == id } }

    func mailbox(id: String) -> MailboxInfo? {
        for (_, boxes) in mailboxes {
            if let box = boxes.first(where: { $0.id == id }) { return box }
        }
        return nil
    }

    func mailbox(accountID: UUID, role: MailboxRole) -> MailboxInfo? {
        mailboxes[accountID]?.first { $0.role == role }
    }

    func message(id: String) -> MessageSummary? {
        if let results = serverResults, let hit = results.first(where: { $0.id == id }) { return hit }
        guard let hash = id.lastIndex(of: "#") else { return nil }
        let mailboxID = String(id[..<hash])
        return snapshots[mailboxID]?.messages.first { $0.id == id }
    }

    var inboxes: [MailboxInfo] {
        accounts.compactMap { mailbox(accountID: $0.id, role: .inbox) }
    }

    var totalInboxUnread: Int { inboxes.reduce(0) { $0 + $1.unread } }

    var selectionTitle: String {
        switch selection {
        case .allInboxes, .none: return accounts.count > 1 ? "All Inboxes" : "Inbox"
        case .starred: return "Starred"
        case .mailbox(let id):
            guard let box = mailbox(id: id) else { return "Mail" }
            return box.displayName
        }
    }

    var selectionSubtitle: String {
        if serverResults != nil { return "Search results" }
        switch selection {
        case .allInboxes, .none:
            let unread = totalInboxUnread
            return unread == 0 ? "No unread messages" : "\(unread) unread"
        case .starred:
            return ""
        case .mailbox(let id):
            guard let box = mailbox(id: id), let account = account(box.accountID) else { return "" }
            return account.email
        }
    }

    var isUnifiedView: Bool {
        switch selection {
        case .allInboxes, .starred, .none: return accounts.count > 1
        case .mailbox: return false
        }
    }

    /// The current mailbox when one real mailbox is selected.
    var selectedMailbox: MailboxInfo? {
        if case .mailbox(let id) = selection { return mailbox(id: id) }
        return nil
    }

    var visibleMessages: [MessageSummary] {
        if let serverResults { return serverResults }
        var list: [MessageSummary]
        switch selection {
        case .allInboxes, .none:
            list = inboxes.flatMap { snapshots[$0.id]?.messages ?? [] }
        case .starred:
            var seen = Set<String>()
            list = snapshots.values.flatMap { $0.messages }.filter { message in
                guard message.isFlagged else { return false }
                return seen.insert(message.messageID ?? message.id).inserted
            }
        case .mailbox(let id):
            list = snapshots[id]?.messages ?? []
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { m in
                m.subject.localizedCaseInsensitiveContains(query)
                    || m.from.contains { $0.displayName.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query) }
                    || m.to.contains { $0.address.localizedCaseInsensitiveContains(query) }
                    || (m.snippet?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return list.sorted { $0.date > $1.date }
    }

    var isLoadingSelection: Bool {
        switch selection {
        case .allInboxes, .none: return inboxes.contains { loadingMailboxes.contains($0.id) } && visibleMessages.isEmpty
        case .starred: return false
        case .mailbox(let id): return loadingMailboxes.contains(id)
        }
    }

    var canLoadOlder: Bool {
        guard serverResults == nil, let box = selectedMailbox else { return false }
        return snapshots[box.id]?.hasMoreOlder ?? false
    }

    var isLoadingOlder: Bool {
        guard let box = selectedMailbox else { return false }
        return loadingOlder.contains(box.id)
    }

    var selectedMessages: [MessageSummary] {
        selectedMessageIDs.compactMap(message(id:)).sorted { $0.date > $1.date }
    }

    // MARK: Accounts

    @discardableResult
    private func makeSession(for account: AccountConfig) -> AccountSession? {
        guard let password = Keychain.password(for: account.id) else {
            status[account.id] = .failed("The password for this account is missing. Remove the account and add it again.")
            return nil
        }
        let session = AccountSession(account: account, password: password, transport: StreamTransport.factory)
        sessions[account.id] = session
        return session
    }

    /// Signs in with the given settings. Throws a readable error when it can't.
    func verify(_ account: AccountConfig, password: String) async throws {
        let session = AccountSession(account: account, password: password, transport: StreamTransport.factory)
        try await session.verify()
    }

    func addAccount(_ account: AccountConfig, password: String) throws {
        var account = account
        account.colorIndex = (accounts.map(\.colorIndex).max() ?? -1) + 1
        try Keychain.setPassword(password, for: account.id)
        accounts.append(account)
        store.saveAccounts(accounts)
        makeSession(for: account)
        selection = .allInboxes
        refresh(accountID: account.id)
    }

    func updateAccount(_ account: AccountConfig) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        store.saveAccounts(accounts)
        if let session = sessions[account.id] {
            Task { await session.update(account: account) }
        }
    }

    func updatePassword(_ password: String, for id: UUID) {
        do {
            try Keychain.setPassword(password, for: id)
        } catch {
            showBanner(Self.describe(error), isError: true)
            return
        }
        if let old = sessions[id] {
            Task { await old.disconnect() }
        }
        sessions[id] = nil
        status[id] = .idle
        if let account = account(id) { makeSession(for: account) }
        refresh(accountID: id)
    }

    func removeAccount(_ id: UUID) {
        if let session = sessions[id] {
            Task { await session.disconnect() }
        }
        sessions[id] = nil
        Keychain.deletePassword(for: id)
        accounts.removeAll { $0.id == id }
        for box in mailboxes[id] ?? [] { snapshots[box.id] = nil }
        mailboxes[id] = nil
        status[id] = nil
        store.saveAccounts(accounts)
        store.removeData(for: id)
        if case .mailbox(let boxID) = selection, boxID.hasPrefix(id.uuidString) { selection = .allInboxes }
        selectedMessageIDs = selectedMessageIDs.filter { !$0.hasPrefix(id.uuidString) }
        updateBadge()
    }

    // MARK: Syncing

    private func schedulePolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let minutes = max(1, UserDefaults.standard.integer(forKey: SettingsKey.checkInterval))
                try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshAll()
            }
        }
    }

    func refreshAll() {
        for account in accounts { refresh(accountID: account.id) }
    }

    /// Folder list and unread counts, then the inbox and whatever is open.
    func refresh(accountID: UUID) {
        guard let session = sessions[accountID] ?? account(accountID).flatMap({ makeSession(for: $0) }) else { return }
        if status[accountID] == .syncing { return }
        status[accountID] = .syncing
        Task {
            do {
                let boxes = try await session.listMailboxes()
                self.mailboxes[accountID] = boxes
                self.store.saveMailboxes(boxes, accountID: accountID)
                var toSync = boxes.filter { $0.role == .inbox }
                if let current = self.selectedMailbox, current.accountID == accountID, current.role != .inbox {
                    toSync.append(current)
                }
                for box in toSync {
                    try await self.sync(box, session: session)
                }
                self.status[accountID] = .idle
            } catch {
                self.status[accountID] = .failed(Self.describe(error))
            }
            self.updateBadge()
        }
    }

    /// Syncs whatever the sidebar shows right now.
    func refreshSelection() {
        switch selection {
        case .mailbox(let id):
            guard let box = mailbox(id: id), let session = sessions[box.accountID] else { return }
            if snapshots[id] == nil, let cached = store.loadSnapshot(accountID: box.accountID, path: box.path) {
                snapshots[id] = cached
            }
            Task {
                do {
                    try await self.sync(box, session: session)
                } catch {
                    self.showBanner(Self.describe(error), isError: true)
                }
            }
        case .allInboxes, .starred, .none:
            break
        }
    }

    private func sync(_ box: MailboxInfo, session: AccountSession) async throws {
        let previous = snapshots[box.id]
        if previous == nil { loadingMailboxes.insert(box.id) }
        defer { loadingMailboxes.remove(box.id) }
        let result = try await session.sync(path: box.path, snapshot: previous)
        var snapshot = result.snapshot
        if result.didReset { store.removeBodies(accountID: box.accountID, path: box.path) }
        // Keep snippets computed while this sync was running.
        if let current = snapshots[box.id] {
            let snippets = Dictionary(current.messages.compactMap { m in m.snippet.map { (m.uid, $0) } }, uniquingKeysWith: { a, _ in a })
            for index in snapshot.messages.indices where snapshot.messages[index].snippet == nil {
                snapshot.messages[index].snippet = snippets[snapshot.messages[index].uid]
            }
        }
        snapshots[box.id] = snapshot
        store.saveSnapshot(snapshot, accountID: box.accountID, path: box.path)
        let unread = snapshot.messages.filter { !$0.isSeen }.count
        if snapshot.messages.count >= snapshot.exists {
            setUnread(unread, mailboxID: box.id)
        }

        if box.role == .inbox, previous != nil, !result.newMessages.isEmpty,
           UserDefaults.standard.bool(forKey: SettingsKey.notifyNewMail),
           !NSApp.isActive, let account = account(box.accountID) {
            Notifier.notify(result.newMessages.filter { !$0.isSeen }, account: account)
        }
        prefetchSnippets(for: box, session: session)
    }

    /// Downloads the newest bodies in the background so rows can show a preview line.
    private func prefetchSnippets(for box: MailboxInfo, session: AccountSession) {
        guard !prefetching.contains(box.id), let snapshot = snapshots[box.id] else { return }
        let missing = snapshot.messages.prefix(40).filter { $0.snippet == nil && $0.size < 2_000_000 }
        guard !missing.isEmpty else { return }
        prefetching.insert(box.id)
        let uidValidity = snapshot.uidValidity
        Task {
            defer { self.prefetching.remove(box.id) }
            for summary in missing {
                let bytes: [UInt8]
                if let cached = store.loadBody(accountID: box.accountID, path: box.path, uidValidity: uidValidity, uid: summary.uid) {
                    bytes = cached
                } else {
                    guard let fetched = try? await session.fetchBody(path: box.path, uid: summary.uid, channel: .sync) else { return }
                    bytes = fetched
                    store.saveBody(bytes, accountID: box.accountID, path: box.path, uidValidity: uidValidity, uid: summary.uid)
                }
                let parsed = await Task.detached(priority: .utility) { ParsedMessage(bytes: bytes) }.value
                self.applyParsedDetails(parsed, to: summary.id)
            }
            if let snapshot = self.snapshots[box.id] {
                self.store.saveSnapshot(snapshot, accountID: box.accountID, path: box.path)
            }
        }
    }

    private func applyParsedDetails(_ parsed: ParsedMessage, to id: String) {
        updateMessage(id) { message in
            message.snippet = parsed.snippet()
            message.hasAttachments = !parsed.visibleAttachments.isEmpty
        }
    }

    func loadOlder() {
        guard let box = selectedMailbox, let session = sessions[box.accountID],
              let snapshot = snapshots[box.id], !loadingOlder.contains(box.id) else { return }
        loadingOlder.insert(box.id)
        Task {
            defer { self.loadingOlder.remove(box.id) }
            do {
                let updated = try await session.loadOlder(path: box.path, snapshot: snapshot)
                self.snapshots[box.id] = updated
                self.store.saveSnapshot(updated, accountID: box.accountID, path: box.path)
            } catch {
                self.showBanner(Self.describe(error), isError: true)
            }
        }
    }

    // MARK: Search

    /// Searches the server for the current text: every inbox, or the selected mailbox.
    func searchOnServer() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        let targets: [MailboxInfo]
        if let box = selectedMailbox {
            targets = [box]
        } else {
            // Gmail's All Mail covers every label; other accounts search their inbox.
            targets = accounts.compactMap { account in
                account.isGmail ? (mailbox(accountID: account.id, role: .archive) ?? mailbox(accountID: account.id, role: .inbox))
                    : mailbox(accountID: account.id, role: .inbox)
            }
        }
        isSearchingServer = true
        Task {
            var results: [MessageSummary] = []
            var failure: String?
            for box in targets {
                guard let session = sessions[box.accountID] else { continue }
                do {
                    results += try await session.search(path: box.path, query: query)
                } catch {
                    failure = Self.describe(error)
                }
            }
            self.isSearchingServer = false
            guard self.searchText.trimmingCharacters(in: .whitespaces) == query else { return }
            self.serverResults = results.sorted { $0.date > $1.date }
            if let failure { self.showBanner(failure, isError: true) }
        }
    }

    func clearServerSearch() {
        serverResults = nil
        isSearchingServer = false
    }

    // MARK: Reading

    private func openSelectedMessage() {
        readerTask?.cancel()
        guard selectedMessageIDs.count == 1, let id = selectedMessageIDs.first, let summary = message(id: id) else {
            reader = selectedMessageIDs.count > 1 ? .multiple(selectedMessageIDs.count) : .empty
            return
        }
        if case .loaded(let current, _) = reader, current.id == id { return }
        reader = .loading(summary)
        readerTask = Task {
            do {
                let parsed = try await self.loadParsed(summary)
                guard !Task.isCancelled else { return }
                self.reader = .loaded(summary, parsed)
                self.applyParsedDetails(parsed, to: summary.id)
                if !summary.isSeen {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    if !Task.isCancelled, self.selectedMessageIDs == [summary.id] {
                        self.setRead([summary.id], read: true)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.reader = .failed(summary, Self.describe(error))
            }
        }
    }

    func retryOpen() {
        let ids = selectedMessageIDs
        reader = .empty
        selectedMessageIDs = []
        selectedMessageIDs = ids
    }

    func loadParsed(_ summary: MessageSummary) async throws -> ParsedMessage {
        let uidValidity = snapshots[summary.mailboxID]?.uidValidity ?? 0
        if let bytes = store.loadBody(accountID: summary.accountID, path: summary.mailboxPath, uidValidity: uidValidity, uid: summary.uid) {
            return await Task.detached(priority: .userInitiated) { ParsedMessage(bytes: bytes) }.value
        }
        guard let session = sessions[summary.accountID] else {
            throw MailError.invalidInput("This account isn't connected.")
        }
        let bytes = try await session.fetchBody(path: summary.mailboxPath, uid: summary.uid)
        if uidValidity != 0 {
            store.saveBody(bytes, accountID: summary.accountID, path: summary.mailboxPath, uidValidity: uidValidity, uid: summary.uid)
        }
        return await Task.detached(priority: .userInitiated) { ParsedMessage(bytes: bytes) }.value
    }

    // MARK: Message actions (optimistic: the UI changes first, the server follows)

    private func updateMessage(_ id: String, _ change: (inout MessageSummary) -> Void) {
        if let hash = id.lastIndex(of: "#") {
            let mailboxID = String(id[..<hash])
            if var snapshot = snapshots[mailboxID], let index = snapshot.messages.firstIndex(where: { $0.id == id }) {
                change(&snapshot.messages[index])
                snapshots[mailboxID] = snapshot
            }
        }
        if var results = serverResults, let index = results.firstIndex(where: { $0.id == id }) {
            change(&results[index])
            serverResults = results
        }
    }

    private func groupedByMailbox(_ ids: Set<String>) -> [(box: MailboxInfo, messages: [MessageSummary])] {
        let messages = ids.compactMap(message(id:))
        let groups = Dictionary(grouping: messages, by: \.mailboxID)
        return groups.compactMap { key, value in
            guard let box = mailbox(id: key) else { return nil }
            return (box, value)
        }
    }

    private func setUnread(_ count: Int, mailboxID: String) {
        guard let box = mailbox(id: mailboxID), var boxes = mailboxes[box.accountID],
              let index = boxes.firstIndex(where: { $0.id == mailboxID }), boxes[index].unread != count else { return }
        boxes[index].unread = max(0, count)
        mailboxes[box.accountID] = boxes
        updateBadge()
    }

    private func adjustUnread(mailboxID: String, by delta: Int) {
        guard let box = mailbox(id: mailboxID) else { return }
        setUnread(box.unread + delta, mailboxID: mailboxID)
    }

    func setRead(_ ids: Set<String>, read: Bool) {
        for group in groupedByMailbox(ids) {
            let changing = group.messages.filter { $0.isSeen != read }
            guard !changing.isEmpty else { continue }
            for message in changing {
                updateMessage(message.id) { m in
                    if read { m.flags.insert(MessageFlag.seen) } else { m.flags.remove(MessageFlag.seen) }
                }
            }
            adjustUnread(mailboxID: group.box.id, by: read ? -changing.count : changing.count)
            let path = group.box.path
            let uids = changing.map(\.uid)
            perform(on: group.box, failure: "Couldn't update the read state") { session in
                try await session.setFlags(path: path, uids: uids, flags: [MessageFlag.seen], add: read)
            } revert: {
                for message in changing {
                    self.updateMessage(message.id) { m in
                        if read { m.flags.remove(MessageFlag.seen) } else { m.flags.insert(MessageFlag.seen) }
                    }
                }
                self.adjustUnread(mailboxID: group.box.id, by: read ? changing.count : -changing.count)
            }
        }
        persistTouched(ids)
    }

    func toggleRead(_ ids: Set<String>) {
        let messages = ids.compactMap(message(id:))
        // Mixed selection: mark everything read first, like Mail does.
        let markRead = messages.contains { !$0.isSeen }
        setRead(ids, read: markRead)
    }

    func toggleFlag(_ ids: Set<String>) {
        let messages = ids.compactMap(message(id:))
        let flag = messages.contains { !$0.isFlagged }
        for group in groupedByMailbox(ids) {
            for message in group.messages {
                updateMessage(message.id) { m in
                    if flag { m.flags.insert(MessageFlag.flagged) } else { m.flags.remove(MessageFlag.flagged) }
                }
            }
            let path = group.box.path
            let uids = group.messages.map(\.uid)
            perform(on: group.box, failure: flag ? "Couldn't star the message" : "Couldn't remove the star") { session in
                try await session.setFlags(path: path, uids: uids, flags: [MessageFlag.flagged], add: flag)
            } revert: {
                for message in group.messages {
                    self.updateMessage(message.id) { m in
                        if flag { m.flags.remove(MessageFlag.flagged) } else { m.flags.insert(MessageFlag.flagged) }
                    }
                }
            }
        }
        persistTouched(ids)
    }

    func archive(_ ids: Set<String>) {
        moveToRole(ids, role: .archive, done: "Archived", failed: "Couldn't archive")
    }

    func trash(_ ids: Set<String>) {
        moveToRole(ids, role: .trash, done: "Moved to Trash", failed: "Couldn't move to Trash")
    }

    func markSpam(_ ids: Set<String>) {
        moveToRole(ids, role: .junk, done: "Moved to Spam", failed: "Couldn't move to Spam")
    }

    func move(_ ids: Set<String>, to destination: MailboxInfo) {
        let groups = groupedByMailbox(ids).filter { $0.box.id != destination.id && $0.box.accountID == destination.accountID }
        guard !groups.isEmpty else { return }
        let next = messageAfterRemoving(Set(groups.flatMap { $0.messages.map(\.id) }))
        var count = 0
        for group in groups {
            remove(group.messages, from: group.box)
            count += group.messages.count
            let box = group.box
            let uids = group.messages.map(\.uid)
            perform(on: box, failure: "Couldn't move the message") { session in
                try await session.move(path: box.path, uids: uids, to: destination.path)
            } revert: {
                self.restore(group.messages, in: box)
            }
        }
        selectedMessageIDs = next.map { [$0] } ?? []
        showBanner("Moved \(count == 1 ? "1 message" : "\(count) messages") to \(destination.displayName)", isError: false)
    }

    private func moveToRole(_ ids: Set<String>, role: MailboxRole, done: String, failed: String) {
        let groups = groupedByMailbox(ids)
        guard !groups.isEmpty else { return }
        let nextSelection = messageAfterRemoving(ids)
        var moved = 0
        for group in groups {
            guard let session = sessions[group.box.accountID] else { continue }
            let destination = mailbox(accountID: group.box.accountID, role: role)
            if group.box.role == role {
                // Already there. Deleting from Trash removes for good; archiving from Archive does nothing.
                guard role == .trash else { continue }
            }
            remove(group.messages, from: group.box)
            moved += group.messages.count
            let uids = group.messages.map(\.uid)
            let accountID = group.box.accountID
            let box = group.box
            Task {
                do {
                    if box.role == .trash && role == .trash {
                        try await session.deletePermanently(path: box.path, uids: uids)
                    } else if let destination {
                        try await session.move(path: box.path, uids: uids, to: destination.path)
                    } else if role == .archive {
                        // No archive folder yet: create one.
                        try await session.createMailbox("Archive")
                        try await session.move(path: box.path, uids: uids, to: "Archive")
                        self.refresh(accountID: accountID)
                    } else {
                        throw MailError.unsupported("This account has no \(role == .trash ? "Trash" : "Spam") folder.")
                    }
                } catch {
                    self.restore(group.messages, in: box)
                    self.showBanner("\(failed). \(Self.describe(error))", isError: true)
                }
            }
        }
        guard moved > 0 else { return }
        selectedMessageIDs = nextSelection.map { [$0] } ?? []
        let deletedForGood = groups.allSatisfy { $0.box.role == .trash } && role == .trash
        showBanner(deletedForGood ? "Deleted \(moved == 1 ? "1 message" : "\(moved) messages") for good"
                                  : "\(done): \(moved == 1 ? "1 message" : "\(moved) messages")", isError: false)
    }

    /// The row that should be selected after these ids leave the list (the next older one, like Gmail).
    private func messageAfterRemoving(_ ids: Set<String>) -> String? {
        let list = visibleMessages
        guard let lastIndex = list.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        if let after = list[(lastIndex + 1)...].first(where: { !ids.contains($0.id) }) { return after.id }
        return list[..<lastIndex].last(where: { !ids.contains($0.id) })?.id
    }

    private func remove(_ messages: [MessageSummary], from box: MailboxInfo) {
        let removing = Set(messages.map(\.id))
        if var snapshot = snapshots[box.id] {
            snapshot.messages.removeAll { removing.contains($0.id) }
            snapshot.exists = max(0, snapshot.exists - messages.count)
            snapshots[box.id] = snapshot
            store.saveSnapshot(snapshot, accountID: box.accountID, path: box.path)
        }
        serverResults?.removeAll { removing.contains($0.id) }
        adjustUnread(mailboxID: box.id, by: -messages.filter { !$0.isSeen }.count)
    }

    private func restore(_ messages: [MessageSummary], in box: MailboxInfo) {
        guard var snapshot = snapshots[box.id] else { return }
        let existing = Set(snapshot.messages.map(\.id))
        snapshot.messages += messages.filter { !existing.contains($0.id) }
        snapshot.messages.sort { $0.uid > $1.uid }
        snapshot.exists += messages.count
        snapshots[box.id] = snapshot
        store.saveSnapshot(snapshot, accountID: box.accountID, path: box.path)
        adjustUnread(mailboxID: box.id, by: messages.filter { !$0.isSeen }.count)
    }

    private func perform(on box: MailboxInfo, failure: String,
                         _ work: @escaping @Sendable (AccountSession) async throws -> Void,
                         revert: @escaping () -> Void) {
        guard let session = sessions[box.accountID] else { return }
        Task {
            do {
                try await work(session)
            } catch {
                revert()
                self.showBanner("\(failure). \(Self.describe(error))", isError: true)
            }
        }
    }

    private func persistTouched(_ ids: Set<String>) {
        let boxIDs = Set(ids.compactMap { id in id.lastIndex(of: "#").map { String(id[..<$0]) } })
        for boxID in boxIDs {
            guard let box = mailbox(id: boxID), let snapshot = snapshots[boxID] else { continue }
            store.saveSnapshot(snapshot, accountID: box.accountID, path: box.path)
        }
    }

    // MARK: Attachments

    func open(_ attachment: MailAttachment) {
        do {
            let url = try store.temporaryFile(named: attachment.filename, data: attachment.data)
            NSWorkspace.shared.open(url)
        } catch {
            showBanner("Couldn't open \(attachment.filename). \(error.localizedDescription)", isError: true)
        }
    }

    func save(_ attachment: MailAttachment) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(attachment.data).write(to: url)
        } catch {
            showBanner("Couldn't save \(attachment.filename). \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Compose

    func newDraft(to address: String = "") -> ComposeDraft {
        var draft = ComposeDraft()
        draft.accountID = defaultSendingAccount()?.id
        draft.to = address
        if let account = draft.accountID.flatMap(account(_:)), !account.signature.isEmpty {
            draft.body = "\n\n-- \n\(account.signature)"
        }
        return draft
    }

    private func defaultSendingAccount() -> AccountConfig? {
        if let box = selectedMailbox { return account(box.accountID) }
        return accounts.first
    }

    func replyDraft(_ mode: ReplyMode, to summary: MessageSummary) -> ComposeDraft {
        var parsed: ParsedMessage?
        if case .loaded(let open, let message) = reader, open.id == summary.id { parsed = message }
        var draft = ComposeDraft()
        draft.accountID = summary.accountID
        let ownAddresses = Set(accounts.map { $0.email.lowercased() })

        switch mode {
        case .reply, .replyAll:
            let replyTargets = summary.replyTo.isEmpty ? summary.from : summary.replyTo
            var to = replyTargets
            var cc: [EmailAddress] = []
            // Replying to your own sent message goes to its original recipients.
            if replyTargets.allSatisfy({ ownAddresses.contains($0.address.lowercased()) }) {
                to = summary.to
            }
            if mode == .replyAll {
                var seen = Set(to.map { $0.address.lowercased() }).union(ownAddresses)
                for address in summary.to + summary.cc where seen.insert(address.address.lowercased()).inserted {
                    cc.append(address)
                }
            }
            draft.to = to.map(\.editableValue).joined(separator: ", ")
            draft.cc = cc.map(\.editableValue).joined(separator: ", ")
            draft.subject = Self.prefixed(summary.subject, with: "Re:")
            draft.inReplyTo = summary.messageID
            draft.references = summary.references + (summary.messageID.map { [$0] } ?? [])
            draft.answeringMessageID = summary.id
            let when = summary.date.formatted(date: .abbreviated, time: .shortened)
            let quoted = (parsed?.plainText ?? summary.snippet ?? "")
                .components(separatedBy: .newlines)
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            draft.body = "\n\n\(signatureBlock(summary.accountID))On \(when), \(summary.from.first?.editableValue ?? "someone") wrote:\n\(quoted)"
        case .forward:
            draft.subject = Self.prefixed(summary.subject, with: "Fwd:")
            var header = "---------- Forwarded message ----------\n"
            header += "From: \(summary.from.map(\.editableValue).joined(separator: ", "))\n"
            header += "Date: \(summary.date.formatted(date: .long, time: .shortened))\n"
            header += "Subject: \(summary.subjectDisplay)\n"
            header += "To: \(summary.to.map(\.editableValue).joined(separator: ", "))\n"
            if !summary.cc.isEmpty { header += "Cc: \(summary.cc.map(\.editableValue).joined(separator: ", "))\n" }
            draft.body = "\n\n\(signatureBlock(summary.accountID))\(header)\n\(parsed?.plainText ?? summary.snippet ?? "")"
            if let parsed {
                draft.attachments = parsed.visibleAttachments.compactMap {
                    try? store.temporaryFile(named: $0.filename, data: $0.data)
                }
            }
        }
        return draft
    }

    private func signatureBlock(_ accountID: UUID) -> String {
        guard let signature = account(accountID)?.signature, !signature.isEmpty else { return "" }
        return "-- \n\(signature)\n\n"
    }

    private static func prefixed(_ subject: String, with prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) { return trimmed }
        return "\(prefix) \(trimmed)"
    }

    /// Every address seen in cached mail, most frequent first, for To-field suggestions.
    func contactSuggestions(matching query: String, limit: Int = 6) -> [EmailAddress] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        var counts: [String: (EmailAddress, Int)] = [:]
        for snapshot in snapshots.values {
            for message in snapshot.messages {
                for address in message.from + message.to + message.cc {
                    let key = address.address.lowercased()
                    let existing = counts[key]
                    let best = (existing?.0.name == nil && address.name != nil) ? address : (existing?.0 ?? address)
                    counts[key] = (best, (existing?.1 ?? 0) + 1)
                }
            }
        }
        let own = Set(accounts.map { $0.email.lowercased() })
        return counts.values
            .filter { !own.contains($0.0.address.lowercased()) }
            .filter { $0.0.address.lowercased().contains(q) || ($0.0.name?.lowercased().contains(q) ?? false) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    func send(_ draft: ComposeDraft) async throws {
        guard let accountID = draft.accountID, let account = account(accountID), let session = sessions[accountID] else {
            throw MailError.invalidInput("Choose an account to send from.")
        }
        let to = EmailAddress.parseList(draft.to)
        let cc = EmailAddress.parseList(draft.cc)
        let bcc = EmailAddress.parseList(draft.bcc)
        let everyone = to + cc + bcc
        guard !everyone.isEmpty else { throw MailError.invalidInput("Add at least one recipient.") }
        if let bad = everyone.first(where: { !$0.isValid }) {
            throw MailError.invalidInput("\"\(bad.address)\" isn't a valid email address.")
        }
        var attachments: [OutgoingAttachment] = []
        var totalSize = 0
        for url in draft.attachments {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                throw MailError.invalidInput("Couldn't read the attachment \(url.lastPathComponent).")
            }
            totalSize += data.count
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            attachments.append(OutgoingAttachment(filename: url.lastPathComponent, mimeType: mime, data: [UInt8](data)))
        }
        if totalSize > 25 * 1024 * 1024 {
            throw MailError.invalidInput("Attachments add up to \(ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)). Most providers stop at 25 MB.")
        }
        let message = OutgoingMessage(
            from: account.sender, to: to, cc: cc, bcc: bcc,
            subject: draft.subject, textBody: draft.body, attachments: attachments,
            inReplyTo: draft.inReplyTo, references: draft.references
        )
        let sentPath = mailbox(accountID: accountID, role: .sent)?.path
        try await session.send(message, sentPath: sentPath)

        if let answered = draft.answeringMessageID, let original = self.message(id: answered), let box = mailbox(id: original.mailboxID) {
            updateMessage(answered) { $0.flags.insert(MessageFlag.answered) }
            let path = box.path
            let uid = original.uid
            perform(on: box, failure: "Couldn't mark the message as answered") { session in
                try await session.setFlags(path: path, uids: [uid], flags: [MessageFlag.answered], add: true)
            } revert: {}
        }
        showBanner("Message sent", isError: false)
    }

    // MARK: Feedback

    func showBanner(_ text: String, isError: Bool) {
        banner = Banner(text: text, isError: isError)
        bannerTask?.cancel()
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: isError ? 8_000_000_000 : 4_000_000_000)
            if !Task.isCancelled { self.banner = nil }
        }
    }

    private func updateBadge() {
        Notifier.setBadge(totalInboxUnread)
    }

    static func describe(_ error: Error) -> String {
        if let mail = error as? MailError { return mail.message }
        return error.localizedDescription
    }
}
