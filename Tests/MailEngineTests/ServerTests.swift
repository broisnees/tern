import XCTest
@testable import MailEngine

final class SMTPTests: XCTestCase {
    func testSendConversation() async throws {
        let transport = ScriptedTransport(greeting: "220 smtp.test ESMTP\r\n") { line in
            switch true {
            case line.hasPrefix("EHLO"): return "250-smtp.test\r\n250-SIZE 1000\r\n250 AUTH LOGIN PLAIN\r\n"
            case line.hasPrefix("AUTH PLAIN"): return "235 2.7.0 Accepted\r\n"
            case line.hasPrefix("MAIL FROM"): return "250 OK\r\n"
            case line.hasPrefix("RCPT TO"): return "250 OK\r\n"
            case line.hasPrefix("DATA"): return "354 Go ahead\r\n"
            case line.hasSuffix("\r\n.\r\n"): return "250 Queued\r\n"
            case line.hasPrefix("QUIT"): return "221 Bye\r\n"
            default: return "500 What\r\n"
            }
        }
        let client = SMTPClient(transport: transport, security: .tls, heloName: "example.com")
        try await client.connect()
        try await client.authenticate(username: "me@example.com", password: "pw")
        try await client.send(from: "me@example.com", recipients: ["a@x.com", "b@y.com"], message: bytes("Subject: hi\r\n\r\n.body\r\n"))
        await client.quit()
        let written = transport.written
        XCTAssertEqual(written[0], "EHLO example.com\r\n")
        XCTAssertEqual(written[1], "AUTH PLAIN " + Data("\0me@example.com\0pw".utf8).base64EncodedString() + "\r\n")
        XCTAssertEqual(written[3], "RCPT TO:<a@x.com>\r\n")
        XCTAssertEqual(written[6], "Subject: hi\r\n\r\n..body\r\n.\r\n")
    }

    func testRejectedPassword() async throws {
        let transport = ScriptedTransport(greeting: "220 ready\r\n") { line in
            if line.hasPrefix("EHLO") { return "250-x\r\n250 AUTH PLAIN\r\n" }
            if line.hasPrefix("AUTH") { return "535 5.7.8 Username and Password not accepted\r\n" }
            return "221 bye\r\n"
        }
        let client = SMTPClient(transport: transport, security: .tls)
        try await client.connect()
        do {
            try await client.authenticate(username: "u", password: "p")
            XCTFail("expected failure")
        } catch MailError.authenticationFailed(let detail) {
            XCTAssertTrue(detail.contains("not accepted"))
        }
    }
}

/// Runs against the local Dovecot started for development (127.0.0.1:10143). Skips when it isn't running.
final class IMAPIntegrationTests: XCTestCase {
    let accountID = UUID()

    func makeSession() -> AccountSession {
        let account = AccountConfig(
            id: accountID, senderName: "Tester", email: "tester@example.com", providerID: "other",
            imap: ServerConfig(host: "127.0.0.1", port: 10143, security: .none, username: "tester@example.com"),
            smtp: ServerConfig(host: "127.0.0.1", port: 10025, security: .none, username: "tester@example.com")
        )
        return AccountSession(account: account, password: "secret pa\"ss") { host, port, _ in
            SocketTransport(host: host, port: port)
        }
    }

    func requireServer() async throws {
        let probe = SocketTransport(host: "127.0.0.1", port: 10143)
        do {
            try await probe.connect()
            probe.close()
        } catch {
            throw XCTSkip("Dovecot test server not running on 127.0.0.1:10143")
        }
    }

    func sample(_ n: Int, subject: String) -> [UInt8] {
        let message = OutgoingMessage(
            from: EmailAddress(name: "Sender \(n)", address: "sender\(n)@example.com"),
            to: [EmailAddress(address: "tester@example.com")],
            subject: subject,
            textBody: "Body number \(n). Unique-token-\(n)",
            date: Date(timeIntervalSince1970: 1_790_000_000 + Double(n) * 60)
        )
        return MessageBuilder.build(message)
    }

    func testFullMailboxLifecycle() async throws {
        try await requireServer()
        let session = makeSession()
        let box = "Test-\(UUID().uuidString.prefix(8))"
        try await session.createMailbox(box)

        // Synchronizing literals (no LITERAL+) for the first append.
        try await session.withIMAP(.interactive) { client in
            await client.setAvoidNonSynchronizingLiterals(true)
            try await client.append(to: box, message: self.sample(1, subject: "Première"), flags: [])
            await client.setAvoidNonSynchronizingLiterals(false)
        }
        for n in 2...5 {
            try await session.append(path: box, message: sample(n, subject: "Message \(n)"), flags: n == 3 ? [MessageFlag.seen] : [])
        }

        let mailboxes = try await session.listMailboxes()
        XCTAssertEqual(mailboxes.first?.role, .inbox)
        XCTAssertTrue(mailboxes.contains { $0.role == .sent })
        XCTAssertTrue(mailboxes.contains { $0.role == .archive && $0.path == "Archive" })
        let testBox = try XCTUnwrap(mailboxes.first { $0.path == box })
        XCTAssertEqual(testBox.total, 5)
        XCTAssertEqual(testBox.unread, 4)

        // First sync takes the newest 3 only.
        var result = try await session.sync(path: box, snapshot: nil, initialCount: 3)
        XCTAssertEqual(result.snapshot.messages.map(\.subject), ["Message 5", "Message 4", "Message 3"])
        XCTAssertTrue(result.snapshot.hasMoreOlder)
        XCTAssertTrue(result.snapshot.messages[2].isSeen)
        XCTAssertEqual(result.snapshot.messages[0].from.first?.name, "Sender 5")

        // Older page.
        var snapshot = try await session.loadOlder(path: box, snapshot: result.snapshot, count: 10)
        XCTAssertEqual(snapshot.messages.count, 5)
        XCTAssertEqual(snapshot.messages.last?.subject, "Première")
        XCTAssertFalse(snapshot.hasMoreOlder)

        // Flag changes, a new arrival and a move show up in the next sync.
        let m5 = snapshot.messages[0], m4 = snapshot.messages[1]
        try await session.setFlags(path: box, uids: [m5.uid], flags: [MessageFlag.seen, MessageFlag.flagged], add: true)
        try await session.append(path: box, message: sample(6, subject: "Message 6"), flags: [])
        try await session.move(path: box, uids: [m4.uid], to: "Archive")
        result = try await session.sync(path: box, snapshot: snapshot, initialCount: 3)
        snapshot = result.snapshot
        XCTAssertEqual(result.newMessages.map(\.subject), ["Message 6"])
        XCTAssertEqual(snapshot.messages.map(\.subject), ["Message 6", "Message 5", "Message 3", "Message 2", "Première"])
        XCTAssertTrue(snapshot.messages[1].isFlagged)

        // Body fetch parses back to what we sent.
        let body = try await session.fetchBody(path: box, uid: snapshot.messages[0].uid)
        let parsed = ParsedMessage(bytes: body)
        XCTAssertEqual(parsed.subject, "Message 6")
        XCTAssertEqual(parsed.snippet(), "Body number 6. Unique-token-6")

        // Server search.
        let hits = try await session.search(path: box, query: "Unique-token-2")
        XCTAssertEqual(hits.map(\.subject), ["Message 2"])
        let accented = try await session.search(path: box, query: "Première")
        XCTAssertEqual(accented.count, 1)

        // Permanent delete.
        try await session.deletePermanently(path: box, uids: [snapshot.messages[0].uid])
        result = try await session.sync(path: box, snapshot: snapshot)
        XCTAssertEqual(result.snapshot.messages.count, 4)

        // A dropped connection is reopened transparently.
        try await session.withIMAP(.sync) { client in await client.close() }
        let again = try await session.sync(path: box, snapshot: result.snapshot)
        XCTAssertEqual(again.snapshot.messages.count, 4)

        await session.disconnect()
    }

    func testWrongPassword() async throws {
        try await requireServer()
        let account = AccountConfig(
            senderName: "T", email: "tester@example.com", providerID: "other",
            imap: ServerConfig(host: "127.0.0.1", port: 10143, security: .none, username: "tester@example.com"),
            smtp: ServerConfig(host: "127.0.0.1", port: 10025, security: .none, username: "tester@example.com")
        )
        let session = AccountSession(account: account, password: "nope") { host, port, _ in SocketTransport(host: host, port: port) }
        do {
            _ = try await session.listMailboxes()
            XCTFail("expected failure")
        } catch MailError.authenticationFailed {
            // expected
        }
    }
}
