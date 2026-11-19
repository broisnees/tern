import Foundation

public struct IMAPMailboxListing: Sendable, Equatable {
    /// Wire name (modified UTF-7), used in commands.
    public var path: String
    /// Human readable full name.
    public var name: String
    public var delimiter: String?
    /// Lowercased attributes such as `\noselect`, `\sent`.
    public var attributes: Set<String>

    public var isSelectable: Bool {
        !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
    }
}

public struct IMAPSelectInfo: Sendable, Equatable {
    public var exists: Int = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32?
}

public struct IMAPStatusInfo: Sendable, Equatable {
    public var messages: Int?
    public var unseen: Int?
    public var uidNext: UInt32?
}

public struct IMAPFetchedMessage: Sendable {
    public var sequence: Int
    public var uid: UInt32?
    public var flags: [String]?
    public var internalDate: Date?
    public var size: Int?
    public var header: [UInt8]?
    public var body: [UInt8]?
}

public enum IMAPCommandPart: Sendable {
    case text(String)
    case literal([UInt8])
}

/// A single IMAP connection. Commands run one at a time; callers that need a sequence
/// (SELECT then FETCH) must serialize through `AccountSession`.
public actor IMAPClient {
    private let connection: BufferedConnection
    private let transport: MailTransport
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []
    public private(set) var selectedPath: String?
    public private(set) var isClosed = false
    /// Test hook: ignore LITERAL+ so the synchronizing-literal path runs.
    var avoidNonSynchronizingLiterals = false

    public init(transport: MailTransport, trace: (@Sendable (String) -> Void)? = nil) {
        self.transport = transport
        self.connection = BufferedConnection(transport: transport)
        self.connection.trace = trace
    }

    // MARK: Session

    public func connect() async throws {
        try await transport.connect()
        let greeting = try await readResponse()
        let text = String(decoding: greeting, as: UTF8.self)
        if text.hasPrefix("* BYE") {
            throw MailError.connectionFailed("The server refused the connection: \(text.dropFirst(6))")
        }
        guard text.hasPrefix("* OK") || text.hasPrefix("* PREAUTH") else {
            throw MailError.protocolError("unexpected greeting")
        }
        parseCapabilityCode(in: text)
    }

    public func startTLS() async throws {
        try await execute([.text("STARTTLS")])
        connection.discardBuffer()
        try await transport.startTLS()
        capabilities = []
    }

    public func login(username: String, password: String) async throws {
        if capabilities.isEmpty { try await refreshCapabilities() }
        if capabilities.contains("LOGINDISABLED") {
            throw MailError.unsupported("This server doesn't allow password sign-in on an unencrypted connection. Turn on SSL/TLS.")
        }
        do {
            let untagged = try await execute(
                [.text("LOGIN ")] + quoted(username) + [.text(" ")] + quoted(password),
                redacted: true
            )
            _ = untagged
        } catch MailError.commandFailed(let detail) {
            throw MailError.authenticationFailed(detail)
        }
        // Many servers send fresh capabilities after login.
        try await refreshCapabilities()
    }

    public func refreshCapabilities() async throws {
        let responses = try await execute([.text("CAPABILITY")])
        for r in responses where r.hasPrefixCaseInsensitive("* CAPABILITY ") {
            setCapabilities(from: String(decoding: r.dropFirst(13), as: UTF8.self))
        }
    }

    public func logout() async {
        if !isClosed {
            _ = try? await execute([.text("LOGOUT")])
        }
        close()
    }

    public func close() {
        isClosed = true
        selectedPath = nil
        transport.close()
    }

    public func noop() async throws {
        try await execute([.text("NOOP")])
    }

    public func hasCapability(_ name: String) -> Bool { capabilities.contains(name.uppercased()) }

    func setAvoidNonSynchronizingLiterals(_ value: Bool) { avoidNonSynchronizingLiterals = value }

    // MARK: Mailboxes

    public func listMailboxes() async throws -> [IMAPMailboxListing] {
        let responses = try await execute([.text("LIST \"\" \"*\"")])
        var result: [IMAPMailboxListing] = []
        for raw in responses where raw.hasPrefixCaseInsensitive("* LIST ") {
            guard let tokens = try? IMAPTokenizer.parse(raw), tokens.count >= 5 else { continue }
            let attributes = Set((tokens[2].list ?? []).compactMap { $0.text?.lowercased() })
            let delimiter = tokens[3].text
            guard let path = tokens[4].text else { continue }
            result.append(IMAPMailboxListing(
                path: path,
                name: ModifiedUTF7.decode(path),
                delimiter: delimiter,
                attributes: attributes
            ))
        }
        return result
    }

    public func status(_ path: String) async throws -> IMAPStatusInfo {
        let responses = try await execute([.text("STATUS ")] + quoted(path) + [.text(" (MESSAGES UNSEEN UIDNEXT)")])
        var info = IMAPStatusInfo()
        for raw in responses where raw.hasPrefixCaseInsensitive("* STATUS ") {
            guard let tokens = try? IMAPTokenizer.parse(raw), let items = tokens.last?.list else { continue }
            var k = 0
            while k + 1 < items.count {
                let key = items[k].text?.uppercased() ?? ""
                let value = items[k + 1].int
                switch key {
                case "MESSAGES": info.messages = value
                case "UNSEEN": info.unseen = value
                case "UIDNEXT": info.uidNext = value.map { UInt32(clamping: $0) }
                default: break
                }
                k += 2
            }
        }
        return info
    }

    @discardableResult
    public func select(_ path: String) async throws -> IMAPSelectInfo {
        selectedPath = nil
        let responses = try await execute([.text("SELECT ")] + quoted(path))
        var info = IMAPSelectInfo()
        for raw in responses {
            let text = String(decoding: raw, as: UTF8.self)
            let parts = text.split(separator: " ", maxSplits: 3)
            if parts.count >= 3, parts[2].uppercased() == "EXISTS", let n = Int(parts[1]) {
                info.exists = n
            }
            if let v = responseCode("UIDVALIDITY", in: text) { info.uidValidity = UInt32(clamping: v) }
            if let v = responseCode("UIDNEXT", in: text) { info.uidNext = UInt32(clamping: v) }
        }
        selectedPath = path
        return info
    }

    public func create(_ path: String) async throws {
        try await execute([.text("CREATE ")] + quoted(path))
    }

    // MARK: Messages

    public static let summaryHeaderFields = "FROM TO CC REPLY-TO SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES CONTENT-TYPE"

    /// Fetches flags, dates, sizes and summary headers. `set` is a sequence set unless `byUID` is true.
    public func fetchSummaries(_ set: String, byUID: Bool) async throws -> [IMAPFetchedMessage] {
        let items = "(UID FLAGS INTERNALDATE RFC822.SIZE BODY.PEEK[HEADER.FIELDS (\(Self.summaryHeaderFields))])"
        return try await fetch(set, items: items, byUID: byUID)
    }

    public func fetchFlags(uids set: String) async throws -> [IMAPFetchedMessage] {
        try await fetch(set, items: "(UID FLAGS)", byUID: true)
    }

    public func fetchFullMessage(uid: UInt32) async throws -> [UInt8]? {
        let results = try await fetch("\(uid)", items: "(UID BODY.PEEK[])", byUID: true)
        return results.first(where: { $0.uid == uid })?.body
    }

    public func fetch(_ set: String, items: String, byUID: Bool) async throws -> [IMAPFetchedMessage] {
        let command = (byUID ? "UID FETCH " : "FETCH ") + set + " " + items
        let responses = try await execute([.text(command)])
        var result: [IMAPFetchedMessage] = []
        for raw in responses {
            guard let message = Self.parseFetch(raw) else { continue }
            if byUID && message.uid == nil { continue } // unsolicited flag updates
            result.append(message)
        }
        return result
    }

    static func parseFetch(_ raw: [UInt8]) -> IMAPFetchedMessage? {
        // "* 12 FETCH (...)"
        guard raw.count > 2, raw[0] == UInt8(ascii: "*") else { return nil }
        guard let tokens = try? IMAPTokenizer.parse(raw), tokens.count >= 4,
              tokens[2].text?.uppercased() == "FETCH",
              let seq = tokens[1].int,
              let items = tokens[3].list else { return nil }
        var message = IMAPFetchedMessage(sequence: seq)
        var k = 0
        while k + 1 < items.count {
            let key = (items[k].text ?? "").uppercased()
            let value = items[k + 1]
            switch key {
            case "UID":
                message.uid = value.int.map { UInt32(clamping: $0) }
            case "FLAGS":
                message.flags = (value.list ?? []).compactMap { $0.text }.map(MessageFlag.normalize)
            case "INTERNALDATE":
                message.internalDate = value.text.flatMap(MailDate.parseInternalDate)
            case "RFC822.SIZE":
                message.size = value.int
            default:
                if key.hasPrefix("BODY[HEADER") || key.hasPrefix("RFC822.HEADER") {
                    message.header = value.bytes ?? []
                } else if key.hasPrefix("BODY[]") || key == "RFC822" {
                    message.body = value.bytes ?? []
                }
            }
            k += 2
        }
        return message
    }

    public func store(uids set: String, flags: [String], add: Bool) async throws {
        guard !set.isEmpty, !flags.isEmpty else { return }
        let op = add ? "+FLAGS.SILENT" : "-FLAGS.SILENT"
        try await execute([.text("UID STORE \(set) \(op) (\(flags.joined(separator: " ")))")])
    }

    public func copy(uids set: String, to path: String) async throws {
        try await execute([.text("UID COPY \(set) ")] + quoted(path))
    }

    /// Moves messages out of the selected mailbox. Falls back to COPY + delete without MOVE.
    public func move(uids set: String, to path: String) async throws {
        guard !set.isEmpty else { return }
        if hasCapability("MOVE") {
            try await execute([.text("UID MOVE \(set) ")] + quoted(path))
        } else {
            try await copy(uids: set, to: path)
            try await deletePermanently(uids: set)
        }
    }

    /// Flags messages \Deleted and expunges them (only those UIDs when UIDPLUS is available).
    public func deletePermanently(uids set: String) async throws {
        guard !set.isEmpty else { return }
        try await store(uids: set, flags: ["\\Deleted"], add: true)
        if hasCapability("UIDPLUS") {
            try await execute([.text("UID EXPUNGE \(set)")])
        } else {
            try await execute([.text("EXPUNGE")])
        }
    }

    public func append(to path: String, message: [UInt8], flags: [String], date: Date? = nil) async throws {
        var parts: [IMAPCommandPart] = [.text("APPEND ")] + quoted(path)
        if !flags.isEmpty { parts.append(.text(" (\(flags.joined(separator: " ")))")) }
        if let date { parts.append(.text(" \"\(MailDate.formatInternalDate(date))\"")) }
        parts.append(.text(" "))
        parts.append(.literal(message))
        try await execute(parts)
    }

    /// `criteria` is passed through; use `search(text:)` for user input.
    public func uidSearch(_ criteria: [IMAPCommandPart]) async throws -> [UInt32] {
        let responses = try await execute([.text("UID SEARCH ")] + criteria)
        var uids: [UInt32] = []
        for raw in responses where raw.hasPrefixCaseInsensitive("* SEARCH") {
            let text = String(decoding: raw, as: UTF8.self)
            for piece in text.split(separator: " ").dropFirst(2) {
                if let n = UInt32(piece) { uids.append(n) }
            }
        }
        return uids
    }

    /// Full-text search in the selected mailbox. Uses Gmail's own search syntax on Gmail.
    public func search(text query: String) async throws -> [UInt32] {
        if hasCapability("X-GM-EXT-1") {
            return try await uidSearch([.text("X-GM-RAW ")] + quoted(query))
        }
        if query.isASCII {
            return try await uidSearch([.text("TEXT ")] + quoted(query))
        }
        return try await uidSearch([.text("CHARSET UTF-8 TEXT ")] + [.literal(Array(query.utf8))])
    }

    // MARK: Command plumbing

    /// Quoted string, or a literal when the value can't be quoted.
    public nonisolated func quoted(_ value: String) -> [IMAPCommandPart] {
        if value.isASCII && !value.contains("\r") && !value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return [.text("\"\(escaped)\"")]
        }
        return [.literal(Array(value.utf8))]
    }

    /// Sends a command and returns its untagged responses. Throws on NO or BAD.
    @discardableResult
    public func execute(_ parts: [IMAPCommandPart], redacted: Bool = false) async throws -> [[UInt8]] {
        guard !isClosed else { throw MailError.connectionClosed }
        tagCounter += 1
        let tag = "M\(tagCounter)"
        let literalPlus = capabilities.contains("LITERAL+") && !avoidNonSynchronizingLiterals

        // Split the command where it must wait for a "+" continuation.
        var segments: [[UInt8]] = []
        var current = Array("\(tag) ".utf8)
        for part in parts {
            switch part {
            case .text(let s):
                current += Array(s.utf8)
            case .literal(let data):
                if literalPlus {
                    current += Array("{\(data.count)+}\r\n".utf8)
                    current += data
                } else {
                    current += Array("{\(data.count)}\r\n".utf8)
                    segments.append(current)
                    current = data
                }
            }
        }
        current += ASCII.crlf
        segments.append(current)

        var untagged: [[UInt8]] = []
        do {
            for (index, segment) in segments.enumerated() {
                try await connection.write(segment, redacted: redacted)
                if index < segments.count - 1 {
                    while true {
                        let response = try await readResponse()
                        if response.first == UInt8(ascii: "+") { break }
                        if response.hasPrefixCaseInsensitive(tag + " ") {
                            throw statusError(response, tag: tag)
                        }
                        untagged.append(response)
                    }
                }
            }
            while true {
                let response = try await readResponse()
                if response.hasPrefixCaseInsensitive(tag + " ") {
                    let rest = Array(response.dropFirst(tag.count + 1))
                    if rest.hasPrefixCaseInsensitive("OK") {
                        parseCapabilityCode(in: String(decoding: rest, as: UTF8.self))
                        return untagged
                    }
                    throw statusError(response, tag: tag)
                }
                if response.hasPrefixCaseInsensitive("* BYE") && !parts.isLogout {
                    close()
                    throw MailError.connectionClosed
                }
                if response.first == UInt8(ascii: "*") {
                    untagged.append(response)
                }
            }
        } catch let error as MailError {
            if error.isConnectionLevel { close() }
            throw error
        }
    }

    private func statusError(_ response: [UInt8], tag: String) -> MailError {
        let text = String(decoding: response.dropFirst(tag.count + 1), as: UTF8.self)
        let detail = text.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? text
        return .commandFailed(detail.trimmed())
    }

    /// Reads one complete response, including any literals it carries.
    private func readResponse() async throws -> [UInt8] {
        var raw: [UInt8] = []
        while true {
            let line = try await connection.readLine()
            raw += line
            if let length = Self.trailingLiteralLength(line) {
                raw += ASCII.crlf
                raw += try await connection.readBytes(length)
                continue
            }
            return raw
        }
    }

    static func trailingLiteralLength(_ line: [UInt8]) -> Int? {
        guard let last = line.last, last == ASCII.closeBrace else { return nil }
        var j = line.count - 2
        if j >= 0 && line[j] == UInt8(ascii: "+") { j -= 1 }
        var digits: [UInt8] = []
        while j >= 0 && ASCII.isDigit(line[j]) {
            digits.insert(line[j], at: 0)
            j -= 1
        }
        guard j >= 0, line[j] == ASCII.openBrace, !digits.isEmpty else { return nil }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func parseCapabilityCode(in text: String) {
        guard let start = text.range(of: "[CAPABILITY ", options: .caseInsensitive),
              let end = text[start.upperBound...].firstIndex(of: "]") else { return }
        setCapabilities(from: String(text[start.upperBound..<end]))
    }

    private func setCapabilities(from list: String) {
        capabilities = Set(list.split(separator: " ").map { $0.uppercased() })
    }

    private func responseCode(_ name: String, in text: String) -> Int? {
        guard let r = text.range(of: "[\(name) ", options: .caseInsensitive) else { return nil }
        let digits = text[r.upperBound...].prefix(while: { $0.isNumber })
        return Int(digits)
    }
}

private extension Array where Element == IMAPCommandPart {
    var isLogout: Bool {
        if case .text(let s) = first { return s == "LOGOUT" }
        return false
    }
}

public enum MessageFlag {
    public static let seen = "\\Seen"
    public static let flagged = "\\Flagged"
    public static let answered = "\\Answered"
    public static let deleted = "\\Deleted"
    public static let draft = "\\Draft"

    /// Canonical spelling for system flags, so set lookups work.
    public static func normalize(_ flag: String) -> String {
        switch flag.lowercased() {
        case "\\seen": return seen
        case "\\flagged": return flagged
        case "\\answered": return answered
        case "\\deleted": return deleted
        case "\\draft": return draft
        case "\\recent": return "\\Recent"
        default: return flag
        }
    }
}
