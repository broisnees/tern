import Foundation

public enum MailboxRole: String, Codable, Sendable, Comparable {
    case inbox, flagged, drafts, sent, archive, junk, trash, important, other

    var sortOrder: Int {
        switch self {
        case .inbox: return 0
        case .flagged: return 1
        case .important: return 2
        case .drafts: return 3
        case .sent: return 4
        case .archive: return 5
        case .junk: return 6
        case .trash: return 7
        case .other: return 8
        }
    }

    public static func < (lhs: MailboxRole, rhs: MailboxRole) -> Bool { lhs.sortOrder < rhs.sortOrder }

    static func detect(path: String, name: String, delimiter: String?, attributes: Set<String>) -> MailboxRole {
        if path.uppercased() == "INBOX" { return .inbox }
        if attributes.contains("\\sent") { return .sent }
        if attributes.contains("\\drafts") { return .drafts }
        if attributes.contains("\\trash") { return .trash }
        if attributes.contains("\\junk") { return .junk }
        if attributes.contains("\\all") || attributes.contains("\\archive") { return .archive }
        if attributes.contains("\\flagged") { return .flagged }
        if attributes.contains("\\important") { return .important }
        let leaf = (delimiter.flatMap { d in name.components(separatedBy: d).last } ?? name).lowercased()
        switch leaf {
        case "sent", "sent items", "sent messages", "sent mail": return .sent
        case "drafts", "draft": return .drafts
        case "trash", "deleted items", "deleted messages", "bin", "deleted": return .trash
        case "spam", "junk", "junk e-mail", "junk email", "bulk mail", "bulk": return .junk
        case "archive", "archives", "all mail": return .archive
        default: return .other
        }
    }
}

public struct MailboxInfo: Codable, Identifiable, Hashable, Sendable {
    /// `accountID|path`
    public var id: String
    public var accountID: UUID
    public var path: String
    public var name: String
    public var delimiter: String?
    public var role: MailboxRole
    public var unread: Int
    public var total: Int

    public init(accountID: UUID, path: String, name: String, delimiter: String?, role: MailboxRole, unread: Int = 0, total: Int = 0) {
        self.id = "\(accountID.uuidString)|\(path)"
        self.accountID = accountID
        self.path = path
        self.name = name
        self.delimiter = delimiter
        self.role = role
        self.unread = unread
        self.total = total
    }

    /// Last path component, with friendly names for the common folders.
    public var displayName: String {
        switch role {
        case .inbox: return "Inbox"
        case .sent: return "Sent"
        case .drafts: return "Drafts"
        case .trash: return "Trash"
        case .junk: return "Spam"
        case .flagged: return "Starred"
        default:
            if let delimiter, !delimiter.isEmpty, let leaf = name.components(separatedBy: delimiter).last, !leaf.isEmpty {
                return leaf
            }
            return name
        }
    }

    /// Nesting level for custom folders ("Work/Clients" is 1).
    public var depth: Int {
        guard role == .other, let delimiter, !delimiter.isEmpty else { return 0 }
        var parts = name.components(separatedBy: delimiter)
        if parts.first == "[Gmail]" || parts.first == "[Google Mail]" { parts.removeFirst() }
        if parts.first?.uppercased() == "INBOX" && parts.count > 1 { parts.removeFirst() }
        return max(0, parts.count - 1)
    }
}

public struct MessageSummary: Codable, Identifiable, Hashable, Sendable {
    /// `accountID|path#uid`
    public var id: String
    public var accountID: UUID
    public var mailboxPath: String
    public var uid: UInt32
    public var messageID: String?
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date
    public var flags: Set<String>
    public var size: Int
    public var hasAttachments: Bool
    public var snippet: String?
    public var inReplyTo: String?
    public var references: [String]

    public static func makeID(accountID: UUID, path: String, uid: UInt32) -> String {
        "\(accountID.uuidString)|\(path)#\(uid)"
    }

    public var mailboxID: String { "\(accountID.uuidString)|\(mailboxPath)" }
    public var isSeen: Bool { flags.contains(MessageFlag.seen) }
    public var isFlagged: Bool { flags.contains(MessageFlag.flagged) }
    public var isAnswered: Bool { flags.contains(MessageFlag.answered) }

    public var senderDisplay: String {
        from.first?.displayName ?? "(no sender)"
    }

    public var subjectDisplay: String {
        subject.isEmpty ? "(no subject)" : subject
    }

    init(accountID: UUID, path: String, fetched: IMAPFetchedMessage) {
        let uid = fetched.uid ?? 0
        let headers = MIMEHeaders(parsing: fetched.header ?? [])
        self.id = Self.makeID(accountID: accountID, path: path, uid: uid)
        self.accountID = accountID
        self.mailboxPath = path
        self.uid = uid
        self.messageID = MessageIDs.parse(headers["Message-ID"] ?? "").first
        self.subject = EncodedWords.decode(headers["Subject"] ?? "").trimmed()
        self.from = EmailAddress.parseList(headers["From"] ?? "")
        self.to = EmailAddress.parseList(headers["To"] ?? "")
        self.cc = EmailAddress.parseList(headers["Cc"] ?? "")
        self.replyTo = EmailAddress.parseList(headers["Reply-To"] ?? "")
        self.date = headers["Date"].flatMap(MailDate.parse) ?? fetched.internalDate ?? Date()
        if let serverDate = fetched.internalDate, self.date.timeIntervalSince(serverDate) > 86_400 {
            // A sender clock far in the future would pin the message to the top; trust the server instead.
            self.date = serverDate
        }
        self.flags = Set(fetched.flags ?? [])
        self.size = fetched.size ?? 0
        let contentType = HeaderValueWithParameters(parsing: headers["Content-Type"] ?? "text/plain")
        self.hasAttachments = contentType.value == "multipart/mixed"
        self.snippet = nil
        self.inReplyTo = MessageIDs.parse(headers["In-Reply-To"] ?? "").first
        self.references = MessageIDs.parse(headers["References"] ?? "")
    }
}

/// What the app keeps on disk for one mailbox.
public struct MailboxSnapshot: Codable, Sendable {
    public var uidValidity: UInt32
    public var messages: [MessageSummary]
    public var hasMoreOlder: Bool
    public var exists: Int

    public init(uidValidity: UInt32, messages: [MessageSummary] = [], hasMoreOlder: Bool = false, exists: Int = 0) {
        self.uidValidity = uidValidity
        self.messages = messages
        self.hasMoreOlder = hasMoreOlder
        self.exists = exists
    }
}

public struct SyncResult: Sendable {
    public var snapshot: MailboxSnapshot
    /// Messages that arrived since the previous sync (empty on the first sync).
    public var newMessages: [MessageSummary]
    /// True when UIDVALIDITY changed and cached bodies are stale.
    public var didReset: Bool
}
