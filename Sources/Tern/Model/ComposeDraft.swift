import Foundation

/// Everything a compose window starts from. Codable so it can open its own window.
struct ComposeDraft: Codable, Hashable, Identifiable {
    var id = UUID()
    var accountID: UUID?
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [URL] = []
    var inReplyTo: String?
    var references: [String] = []
    /// Message to flag as answered once the reply is sent.
    var answeringMessageID: String?

    var showsCcBcc: Bool { !cc.isEmpty || !bcc.isEmpty }

    var isEmpty: Bool {
        to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachments.isEmpty
    }
}

enum ReplyMode {
    case reply, replyAll, forward
}
