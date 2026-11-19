import Foundation

public struct SMTPReply: Sendable {
    public var code: Int
    public var lines: [String]
    public var text: String { lines.joined(separator: " ") }
}

public actor SMTPClient {
    private let connection: BufferedConnection
    private let transport: MailTransport
    private let security: ConnectionSecurity
    private let heloName: String
    public private(set) var extensions: [String: String] = [:]

    public init(transport: MailTransport, security: ConnectionSecurity, heloName: String = "localhost",
                trace: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.security = security
        self.heloName = heloName
        self.connection = BufferedConnection(transport: transport)
        self.connection.trace = trace
    }

    public func connect() async throws {
        try await transport.connect()
        let greeting = try await readReply()
        guard greeting.code == 220 else {
            throw MailError.connectionFailed("The mail server refused the connection: \(greeting.text)")
        }
        try await ehlo()
        if security == .startTLS {
            guard extensions["STARTTLS"] != nil else {
                throw MailError.unsupported("The outgoing server doesn't offer STARTTLS. Try port 465 with SSL/TLS.")
            }
            try await expect(command: "STARTTLS", codes: [220])
            connection.discardBuffer()
            try await transport.startTLS()
            try await ehlo()
        }
    }

    private func ehlo() async throws {
        var reply = try await send("EHLO \(heloName)")
        if reply.code != 250 {
            reply = try await send("HELO \(heloName)")
            guard reply.code == 250 else { throw MailError.commandFailed(reply.text) }
            extensions = [:]
            return
        }
        var ext: [String: String] = [:]
        for line in reply.lines.dropFirst() {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            ext[key.uppercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
        extensions = ext
    }

    public func authenticate(username: String, password: String) async throws {
        let mechanisms = Set((extensions["AUTH"] ?? "").uppercased().split(separator: " ").map(String.init))
        if mechanisms.contains("PLAIN") || mechanisms.isEmpty {
            let token = Data(([0] + Array(username.utf8) + [0] + Array(password.utf8))).base64EncodedString()
            let reply = try await send("AUTH PLAIN \(token)", redacted: true)
            try checkAuth(reply)
        } else if mechanisms.contains("LOGIN") {
            var reply = try await send("AUTH LOGIN")
            guard reply.code == 334 else { throw MailError.authenticationFailed(reply.text) }
            reply = try await send(Data(username.utf8).base64EncodedString(), redacted: true)
            guard reply.code == 334 else { throw MailError.authenticationFailed(reply.text) }
            reply = try await send(Data(password.utf8).base64EncodedString(), redacted: true)
            try checkAuth(reply)
        } else {
            throw MailError.unsupported("This outgoing server only accepts sign-in methods Tern doesn't support yet (\(mechanisms.sorted().joined(separator: ", "))).")
        }
    }

    private func checkAuth(_ reply: SMTPReply) throws {
        guard reply.code == 235 else { throw MailError.authenticationFailed(reply.text) }
    }

    /// Sends one message. `message` must use CRLF line endings.
    public func send(from sender: String, recipients: [String], message: [UInt8]) async throws {
        guard !recipients.isEmpty else { throw MailError.invalidInput("Add at least one recipient.") }
        try await expect(command: "MAIL FROM:<\(sender)>", codes: [250])
        var accepted = 0
        var rejected: [String] = []
        for recipient in recipients {
            let reply = try await send("RCPT TO:<\(recipient)>")
            if reply.code == 250 || reply.code == 251 {
                accepted += 1
            } else {
                rejected.append("\(recipient) (\(reply.text))")
            }
        }
        guard accepted > 0, rejected.isEmpty else {
            _ = try? await send("RSET")
            throw MailError.commandFailed("The server didn't accept these recipients: \(rejected.joined(separator: ", "))")
        }
        try await expect(command: "DATA", codes: [354])
        try await connection.write(Self.dotStuff(message))
        let reply = try await readReply()
        guard reply.code == 250 else { throw MailError.commandFailed(reply.text) }
    }

    public func quit() async {
        _ = try? await send("QUIT")
        transport.close()
    }

    /// Escapes lines that start with "." and adds the terminating ".".
    static func dotStuff(_ message: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(message.count + 64)
        var atLineStart = true
        for b in message {
            if atLineStart && b == UInt8(ascii: ".") { out.append(UInt8(ascii: ".")) }
            out.append(b)
            atLineStart = b == ASCII.lf
        }
        if !(out.count >= 2 && out[out.count - 2] == ASCII.cr && out[out.count - 1] == ASCII.lf) {
            out += ASCII.crlf
        }
        out += Array(".\r\n".utf8)
        return out
    }

    @discardableResult
    private func expect(command: String, codes: Set<Int>) async throws -> SMTPReply {
        let reply = try await send(command)
        guard codes.contains(reply.code) else { throw MailError.commandFailed(reply.text) }
        return reply
    }

    private func send(_ command: String, redacted: Bool = false) async throws -> SMTPReply {
        try await connection.write(command + "\r\n", redacted: redacted)
        return try await readReply()
    }

    private func readReply() async throws -> SMTPReply {
        var lines: [String] = []
        while true {
            let raw = String(decoding: try await connection.readLine(), as: UTF8.self)
            guard raw.count >= 3, let code = Int(raw.prefix(3)) else {
                throw MailError.protocolError("bad SMTP reply")
            }
            let rest = raw.dropFirst(3)
            lines.append(rest.count > 1 ? String(rest.dropFirst()) : "")
            if rest.first != "-" {
                return SMTPReply(code: code, lines: lines)
            }
        }
    }
}
