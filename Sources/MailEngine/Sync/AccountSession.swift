import Foundation

/// A FIFO lock for async code.
public actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Everything the app does with one account's servers. Keeps two IMAP connections:
/// one for background sync and one for what the person is waiting on (opening a message, actions),
/// so a long sync never blocks a click.
public actor AccountSession {
    public enum Channel: Sendable { case sync, interactive }

    public private(set) var account: AccountConfig
    private let password: String
    private let makeTransport: TransportFactory
    private let trace: (@Sendable (String) -> Void)?
    private var clients: [Channel: IMAPClient] = [:]
    private let locks: [Channel: AsyncLock] = [.sync: AsyncLock(), .interactive: AsyncLock()]

    public init(account: AccountConfig, password: String, transport: @escaping TransportFactory,
                trace: (@Sendable (String) -> Void)? = nil) {
        self.account = account
        self.password = password
        self.makeTransport = transport
        self.trace = trace
    }

    public func update(account: AccountConfig) {
        self.account = account
    }

    // MARK: Connection management

    private func connectIMAP() async throws -> IMAPClient {
        let config = account.imap
        let client = IMAPClient(transport: makeTransport(config.host, config.port, config.security), trace: trace)
        try await client.connect()
        if config.security == .startTLS {
            try await client.startTLS()
        }
        do {
            try await client.login(username: config.username, password: password)
        } catch MailError.authenticationFailed(let detail) {
            // iCloud documents the bare user name for IMAP; retry with it if the full address failed.
            if account.providerID == "icloud", config.username.contains("@"),
               let local = config.username.split(separator: "@").first {
                await client.logout()
                let retry = IMAPClient(transport: makeTransport(config.host, config.port, config.security), trace: trace)
                try await retry.connect()
                try await retry.login(username: String(local), password: password)
                return retry
            }
            throw MailError.authenticationFailed(detail)
        }
        return client
    }

    /// Runs `body` with exclusive use of one connection, reconnecting once if the connection dropped.
    public func withIMAP<T: Sendable>(_ channel: Channel, retry: Bool = true,
                                      _ body: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        let lock = locks[channel]!
        await lock.lock()
        do {
            let result = try await runWithReconnect(channel, retry: retry, body)
            await lock.unlock()
            return result
        } catch {
            await lock.unlock()
            throw error
        }
    }

    private func runWithReconnect<T: Sendable>(_ channel: Channel, retry: Bool,
                                               _ body: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            let client: IMAPClient
            if let existing = clients[channel], await !existing.isClosed {
                client = existing
            } else {
                client = try await connectIMAP()
                clients[channel] = client
            }
            do {
                return try await body(client)
            } catch let error as MailError where error.isConnectionLevel && retry && attempt == 0 {
                await client.close()
                clients[channel] = nil
                attempt += 1
                continue
            } catch {
                if let mailError = error as? MailError, mailError.isConnectionLevel {
                    await client.close()
                    clients[channel] = nil
                }
                throw error
            }
        }
    }

    public func disconnect() async {
        for (_, client) in clients { await client.logout() }
        clients = [:]
    }

    /// Signs in to both servers without keeping the connections. Used when adding an account.
    public func verify() async throws {
        let client = try await connectIMAP()
        await client.logout()
        let smtp = try await connectSMTP()
        await smtp.quit()
    }

    // MARK: Mailboxes

    public func listMailboxes() async throws -> [MailboxInfo] {
        let accountID = account.id
        return try await withIMAP(.sync) { client in
            let listings = try await client.listMailboxes()
            var result: [MailboxInfo] = []
            for listing in listings where listing.isSelectable {
                var info = MailboxInfo(
                    accountID: accountID,
                    path: listing.path,
                    name: listing.name,
                    delimiter: listing.delimiter,
                    role: MailboxRole.detect(path: listing.path, name: listing.name,
                                             delimiter: listing.delimiter, attributes: listing.attributes)
                )
                if let status = try? await client.status(listing.path) {
                    info.unread = status.unseen ?? 0
                    info.total = status.messages ?? 0
                }
                result.append(info)
            }
            return result.sorted { a, b in
                if a.role != b.role { return a.role < b.role }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    public func unreadCount(path: String) async throws -> Int {
        try await withIMAP(.sync) { client in
            try await client.status(path).unseen ?? 0
        }
    }

    // MARK: Sync

    /// Brings a mailbox snapshot up to date: new messages, flag changes, deletions.
    public func sync(path: String, snapshot: MailboxSnapshot?, initialCount: Int = 100) async throws -> SyncResult {
        let accountID = account.id
        return try await withIMAP(.sync) { client in
            let selected = try await client.select(path)
            var didReset = false
            var snap: MailboxSnapshot
            if let snapshot, snapshot.uidValidity == selected.uidValidity {
                snap = snapshot
            } else {
                didReset = snapshot != nil
                snap = MailboxSnapshot(uidValidity: selected.uidValidity)
            }
            snap.exists = selected.exists
            var newMessages: [MessageSummary] = []

            if selected.exists == 0 {
                snap.messages = []
                snap.hasMoreOlder = false
            } else if snap.messages.isEmpty {
                let start = max(1, selected.exists - initialCount + 1)
                let fetched = try await client.fetchSummaries("\(start):*", byUID: false)
                snap.messages = fetched.filter { $0.uid != nil }
                    .map { MessageSummary(accountID: accountID, path: path, fetched: $0) }
                snap.hasMoreOlder = start > 1
            } else {
                let uids = snap.messages.map(\.uid)
                let maxUID = uids.max() ?? 0
                let minUID = uids.min() ?? 1
                let fresh = try await client.fetchSummaries("\(maxUID + 1):*", byUID: true)
                    .filter { ($0.uid ?? 0) > maxUID }
                newMessages = fresh.map { MessageSummary(accountID: accountID, path: path, fetched: $0) }

                var flagsByUID: [UInt32: Set<String>] = [:]
                for item in try await client.fetchFlags(uids: "\(minUID):\(maxUID)") {
                    if let uid = item.uid { flagsByUID[uid] = Set(item.flags ?? []) }
                }
                snap.messages = snap.messages.compactMap { message in
                    guard let flags = flagsByUID[message.uid] else { return nil } // deleted on the server
                    var updated = message
                    updated.flags = flags
                    return updated
                }
                snap.messages += newMessages
            }
            snap.messages.sort { $0.uid > $1.uid }
            return SyncResult(snapshot: snap, newMessages: newMessages, didReset: didReset)
        }
    }

    /// Fetches the next page of older messages.
    public func loadOlder(path: String, snapshot: MailboxSnapshot, count: Int = 100) async throws -> MailboxSnapshot {
        let accountID = account.id
        return try await withIMAP(.sync) { client in
            let selected = try await client.select(path)
            var snap = snapshot
            guard selected.uidValidity == snapshot.uidValidity else { return snapshot }
            let minUID = snapshot.messages.map(\.uid).min() ?? UInt32.max
            guard minUID > 1 else {
                snap.hasMoreOlder = false
                return snap
            }
            let older = try await client.uidSearch([.text("UID 1:\(minUID - 1)")]).filter { $0 < minUID }.sorted()
            let page = Array(older.suffix(count))
            if !page.isEmpty {
                let fetched = try await client.fetchSummaries(IMAPSet.string(from: page), byUID: true)
                snap.messages += fetched.map { MessageSummary(accountID: accountID, path: path, fetched: $0) }
                snap.messages.sort { $0.uid > $1.uid }
            }
            snap.hasMoreOlder = older.count > page.count
            return snap
        }
    }

    public func fetchBody(path: String, uid: UInt32, channel: Channel = .interactive) async throws -> [UInt8] {
        try await withIMAP(channel) { client in
            if await client.selectedPath != path { try await client.select(path) }
            guard let body = try await client.fetchFullMessage(uid: uid) else {
                throw MailError.commandFailed("This message no longer exists on the server.")
            }
            return body
        }
    }

    public func search(path: String, query: String, limit: Int = 100) async throws -> [MessageSummary] {
        let accountID = account.id
        return try await withIMAP(.interactive) { client in
            if await client.selectedPath != path { try await client.select(path) }
            let uids = try await client.search(text: query).sorted().suffix(limit)
            guard !uids.isEmpty else { return [] }
            let fetched = try await client.fetchSummaries(IMAPSet.string(from: uids), byUID: true)
            return fetched.map { MessageSummary(accountID: accountID, path: path, fetched: $0) }
                .sorted { $0.date > $1.date }
        }
    }

    // MARK: Actions

    public func setFlags(path: String, uids: [UInt32], flags: [String], add: Bool) async throws {
        try await withIMAP(.interactive) { client in
            if await client.selectedPath != path { try await client.select(path) }
            try await client.store(uids: IMAPSet.string(from: uids), flags: flags, add: add)
        }
    }

    public func move(path: String, uids: [UInt32], to destination: String) async throws {
        try await withIMAP(.interactive, retry: false) { client in
            if await client.selectedPath != path { try await client.select(path) }
            try await client.move(uids: IMAPSet.string(from: uids), to: destination)
        }
    }

    public func deletePermanently(path: String, uids: [UInt32]) async throws {
        try await withIMAP(.interactive) { client in
            if await client.selectedPath != path { try await client.select(path) }
            try await client.deletePermanently(uids: IMAPSet.string(from: uids))
        }
    }

    public func createMailbox(_ path: String) async throws {
        try await withIMAP(.interactive) { client in
            try await client.create(path)
        }
    }

    public func append(path: String, message: [UInt8], flags: [String]) async throws {
        try await withIMAP(.interactive, retry: false) { client in
            try await client.append(to: path, message: message, flags: flags)
        }
    }

    // MARK: Sending

    private func connectSMTP() async throws -> SMTPClient {
        let config = account.smtp
        let heloDomain = account.email.split(separator: "@").last.map(String.init) ?? "localhost"
        let client = SMTPClient(transport: makeTransport(config.host, config.port, config.security),
                                security: config.security, heloName: heloDomain, trace: trace)
        try await client.connect()
        try await client.authenticate(username: config.username, password: password)
        return client
    }

    /// Sends the message and makes sure a copy lands in Sent.
    public func send(_ message: OutgoingMessage, sentPath: String?) async throws {
        let bytes = MessageBuilder.build(message)
        let smtp = try await connectSMTP()
        do {
            try await smtp.send(from: account.email, recipients: message.envelopeRecipients, message: bytes)
        } catch {
            await smtp.quit()
            throw error
        }
        await smtp.quit()

        // Gmail files sent mail itself. Others may or may not, so check before adding a copy.
        guard let sentPath, !account.isGmail else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let messageID = message.messageID
        let alreadyFiled = (try? await withIMAP(.interactive) { client in
            try await client.select(sentPath)
            return try await client.uidSearch([.text("HEADER Message-ID ")] + client.quoted("<\(messageID)>"))
        }) ?? []
        if alreadyFiled.isEmpty {
            try? await append(path: sentPath, message: bytes, flags: [MessageFlag.seen])
        }
    }
}
