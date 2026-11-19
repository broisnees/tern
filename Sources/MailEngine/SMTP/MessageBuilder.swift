import Foundation

public struct OutgoingAttachment: Sendable, Hashable {
    public var filename: String
    public var mimeType: String
    public var data: [UInt8]

    public init(filename: String, mimeType: String, data: [UInt8]) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct OutgoingMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var textBody: String
    public var htmlBody: String?
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var messageID: String
    public var date: Date

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String, textBody: String, htmlBody: String? = nil, attachments: [OutgoingAttachment] = [],
                inReplyTo: String? = nil, references: [String] = [], messageID: String? = nil, date: Date = Date()) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.textBody = textBody
        self.htmlBody = htmlBody
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        let domain = from.address.split(separator: "@").last.map(String.init) ?? "tern.local"
        self.messageID = messageID ?? "\(UUID().uuidString.lowercased())@\(domain)"
        self.date = date
    }

    /// Everyone the server must deliver to, Bcc included.
    public var envelopeRecipients: [String] {
        var seen = Set<String>()
        return (to + cc + bcc).map(\.address).filter { seen.insert($0.lowercased()).inserted }
    }
}

public enum MessageBuilder {
    /// RFC 5322 bytes with CRLF line endings. Bcc is never written into the headers.
    public static func build(_ m: OutgoingMessage) -> [UInt8] {
        var lines: [String] = []
        lines.append("Date: \(MailDate.formatHeader(m.date))")
        lines.append("From: \([m.from].headerValue(fieldName: "From"))")
        if !m.to.isEmpty { lines.append("To: \(m.to.headerValue(fieldName: "To"))") }
        if !m.cc.isEmpty { lines.append("Cc: \(m.cc.headerValue(fieldName: "Cc"))") }
        lines.append("Subject: \(EncodedWords.encodeIfNeeded(m.subject))")
        lines.append("Message-ID: <\(m.messageID)>")
        if let inReplyTo = m.inReplyTo { lines.append("In-Reply-To: <\(inReplyTo)>") }
        if !m.references.isEmpty {
            lines.append("References: " + m.references.map { "<\($0)>" }.joined(separator: "\r\n "))
        }
        lines.append("MIME-Version: 1.0")
        lines.append("User-Agent: Tern")

        let textPart = Part(
            headers: ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
            body: TextCodecs.encodeQuotedPrintable(m.textBody)
        )
        var bodyPart = textPart
        if let html = m.htmlBody {
            let htmlPart = Part(
                headers: ["Content-Type: text/html; charset=utf-8", "Content-Transfer-Encoding: quoted-printable"],
                body: TextCodecs.encodeQuotedPrintable(html)
            )
            bodyPart = multipart("alternative", [textPart, htmlPart])
        }
        var root = bodyPart
        if !m.attachments.isEmpty {
            root = multipart("mixed", [bodyPart] + m.attachments.map(attachmentPart))
        }
        lines += root.headers
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n" + root.body + "\r\n"
        return Array(text.utf8)
    }

    private struct Part {
        var headers: [String]
        var body: String
    }

    private static func multipart(_ subtype: String, _ parts: [Part]) -> Part {
        let boundary = "=_tern_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        var body = ""
        for part in parts {
            body += "--\(boundary)\r\n"
            body += part.headers.joined(separator: "\r\n") + "\r\n\r\n"
            body += part.body + "\r\n"
        }
        body += "--\(boundary)--"
        return Part(headers: ["Content-Type: multipart/\(subtype);\r\n boundary=\"\(boundary)\""], body: body)
    }

    private static func attachmentPart(_ a: OutgoingAttachment) -> Part {
        let nameParameter: String
        let filenameParameter: String
        if a.filename.isASCII {
            let safe = a.filename.replacingOccurrences(of: "\"", with: "'")
            nameParameter = "name=\"\(safe)\""
            filenameParameter = "filename=\"\(safe)\""
        } else {
            let encodedWord = EncodedWords.encodeIfNeeded(a.filename).replacingOccurrences(of: "\r\n ", with: " ")
            nameParameter = "name=\"\(encodedWord)\""
            let pct = a.filename.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
            filenameParameter = "filename*=UTF-8''\(pct)"
        }
        return Part(
            headers: [
                "Content-Type: \(a.mimeType);\r\n \(nameParameter)",
                "Content-Disposition: attachment;\r\n \(filenameParameter)",
                "Content-Transfer-Encoding: base64",
            ],
            body: TextCodecs.encodeBase64Lines(a.data)
        )
    }
}
