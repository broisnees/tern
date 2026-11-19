import Foundation
import MailEngine

/// On-disk cache in ~/Library/Application Support/Tern:
/// accounts.json, then per account the folder list, one JSON snapshot per mailbox and raw .eml bodies.
final class Persistence: @unchecked Sendable {
    let root: URL
    private let io = DispatchQueue(label: "Tern.persistence", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        root = base.appendingPathComponent("Tern", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: Accounts

    private var accountsURL: URL { root.appendingPathComponent("accounts.json") }

    func loadAccounts() -> [AccountConfig] {
        guard let data = try? Data(contentsOf: accountsURL) else { return [] }
        return (try? decoder.decode([AccountConfig].self, from: data)) ?? []
    }

    func saveAccounts(_ accounts: [AccountConfig]) {
        guard let data = try? encoder.encode(accounts) else { return }
        try? data.write(to: accountsURL, options: .atomic)
    }

    func removeData(for accountID: UUID) {
        let dir = accountDirectory(accountID)
        io.async { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: Mailboxes and snapshots

    private func accountDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("Accounts", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func safeName(_ path: String) -> String {
        Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    func loadMailboxes(accountID: UUID) -> [MailboxInfo] {
        let url = accountDirectory(accountID).appendingPathComponent("mailboxes.json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([MailboxInfo].self, from: data)) ?? []
    }

    func saveMailboxes(_ mailboxes: [MailboxInfo], accountID: UUID) {
        let dir = accountDirectory(accountID)
        let url = dir.appendingPathComponent("mailboxes.json")
        guard let data = try? encoder.encode(mailboxes) else { return }
        io.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private func snapshotURL(accountID: UUID, path: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(Self.safeName(path) + ".json")
    }

    func loadSnapshot(accountID: UUID, path: String) -> MailboxSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL(accountID: accountID, path: path)) else { return nil }
        return try? decoder.decode(MailboxSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: MailboxSnapshot, accountID: UUID, path: String) {
        let url = snapshotURL(accountID: accountID, path: path)
        let encoder = self.encoder
        io.async {
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Bodies

    private func bodyURL(accountID: UUID, path: String, uidValidity: UInt32, uid: UInt32) -> URL {
        accountDirectory(accountID).appendingPathComponent("bodies", isDirectory: true)
            .appendingPathComponent(Self.safeName(path), isDirectory: true)
            .appendingPathComponent("\(uidValidity)-\(uid).eml")
    }

    func loadBody(accountID: UUID, path: String, uidValidity: UInt32, uid: UInt32) -> [UInt8]? {
        guard let data = try? Data(contentsOf: bodyURL(accountID: accountID, path: path, uidValidity: uidValidity, uid: uid)) else { return nil }
        return [UInt8](data)
    }

    func saveBody(_ bytes: [UInt8], accountID: UUID, path: String, uidValidity: UInt32, uid: UInt32) {
        let url = bodyURL(accountID: accountID, path: path, uidValidity: uidValidity, uid: uid)
        io.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(bytes).write(to: url, options: .atomic)
        }
    }

    func removeBodies(accountID: UUID, path: String) {
        let dir = accountDirectory(accountID).appendingPathComponent("bodies", isDirectory: true)
            .appendingPathComponent(Self.safeName(path), isDirectory: true)
        io.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Writes attachments somewhere the system can open them from.
    func temporaryFile(named filename: String, data: [UInt8]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tern", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        try Data(data).write(to: url)
        return url
    }
}
