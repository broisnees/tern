import Foundation

public struct MIMEPart: Sendable {
    public var headers: MIMEHeaders
    /// Body exactly as it appeared (still transfer-encoded). Empty for multiparts.
    public var rawBody: [UInt8]
    public var parts: [MIMEPart]

    public var contentType: HeaderValueWithParameters {
        HeaderValueWithParameters(parsing: headers["Content-Type"] ?? "text/plain; charset=us-ascii")
    }

    public var mimeType: String {
        let value = contentType.value
        return value.contains("/") ? value : "text/plain"
    }

    public var disposition: HeaderValueWithParameters? {
        headers["Content-Disposition"].map(HeaderValueWithParameters.init(parsing:))
    }

    public var contentID: String? {
        guard var id = headers["Content-ID"]?.trimmed(), !id.isEmpty else { return nil }
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        return id
    }

    public var filename: String? {
        let raw = disposition?.parameters["filename"] ?? contentType.parameters["name"]
        guard let raw, !raw.trimmed().isEmpty else { return nil }
        return EncodedWords.decode(raw).trimmed()
    }

    /// Body with the transfer encoding removed.
    public var decodedBody: [UInt8] {
        let encoding = (headers["Content-Transfer-Encoding"] ?? "").trimmed().lowercased()
        switch encoding {
        case "base64": return TextCodecs.decodeBase64(rawBody)
        case "quoted-printable": return TextCodecs.decodeQuotedPrintable(rawBody)
        default: return rawBody
        }
    }

    public var decodedText: String {
        TextCodecs.decode(decodedBody, charset: contentType.parameters["charset"])
    }
}

public enum MIMEParser {
    public static func parse(_ bytes: [UInt8]) -> MIMEPart {
        parse(bytes, depth: 0)
    }

    private static func parse(_ bytes: [UInt8], depth: Int) -> MIMEPart {
        let (headerBytes, body) = splitHeaders(bytes)
        let headers = MIMEHeaders(parsing: headerBytes)
        var part = MIMEPart(headers: headers, rawBody: body, parts: [])
        let type = part.contentType
        if type.value.hasPrefix("multipart/"), let boundary = type.parameters["boundary"], !boundary.isEmpty, depth < 25 {
            part.parts = splitMultipart(body, boundary: boundary).map { parse($0, depth: depth + 1) }
            part.rawBody = []
        }
        return part
    }

    static func splitHeaders(_ bytes: [UInt8]) -> (headers: [UInt8], body: [UInt8]) {
        // A part that starts with a blank line has no headers.
        if bytes.first == ASCII.lf { return ([], Array(bytes.dropFirst())) }
        if bytes.count >= 2 && bytes[0] == ASCII.cr && bytes[1] == ASCII.lf { return ([], Array(bytes.dropFirst(2))) }
        var i = 0
        while i < bytes.count {
            if bytes[i] == ASCII.lf {
                // LF followed by LF, or LF CR LF
                if i + 1 < bytes.count && bytes[i + 1] == ASCII.lf {
                    return (Array(bytes[0..<i]), Array(bytes[(i + 2)...]))
                }
                if i + 2 < bytes.count && bytes[i + 1] == ASCII.cr && bytes[i + 2] == ASCII.lf {
                    return (Array(bytes[0..<i]), Array(bytes[(i + 3)...]))
                }
            }
            i += 1
        }
        return (bytes, [])
    }

    static func splitMultipart(_ body: [UInt8], boundary: String) -> [[UInt8]] {
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [[UInt8]] = []
        var partStart: Int?
        var lineStart = 0
        let n = body.count
        while lineStart < n {
            var lineEnd = lineStart
            while lineEnd < n && body[lineEnd] != ASCII.lf { lineEnd += 1 }
            let nextLine = lineEnd + 1
            if body[lineStart] == UInt8(ascii: "-"), lineEnd - lineStart >= delimiter.count,
               Array(body[lineStart..<(lineStart + delimiter.count)]) == delimiter {
                let rest = Array(body[(lineStart + delimiter.count)..<lineEnd]).trimmingWhitespace()
                let isClose = rest == [UInt8(ascii: "-"), UInt8(ascii: "-")]
                if rest.isEmpty || isClose {
                    if let start = partStart {
                        // The line break before the delimiter belongs to the delimiter.
                        var end = lineStart
                        if end > start && body[end - 1] == ASCII.lf { end -= 1 }
                        if end > start && body[end - 1] == ASCII.cr { end -= 1 }
                        parts.append(Array(body[start..<max(start, end)]))
                    }
                    if isClose { return parts }
                    partStart = min(nextLine, n)
                }
            }
            lineStart = nextLine
        }
        // Missing close delimiter: keep what we have.
        if let start = partStart, start < n {
            parts.append(Array(body[start..<n]))
        }
        return parts
    }
}

public struct MailAttachment: Identifiable, Sendable, Hashable {
    public var id: Int
    public var filename: String
    public var mimeType: String
    public var data: [UInt8]
    public var contentID: String?
    public var isInline: Bool

    public var size: Int { data.count }
}

/// A message ready to show: bodies picked, attachments collected.
public struct ParsedMessage: Sendable {
    public var headers: MIMEHeaders
    public var subject: String
    public var from: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var date: Date?
    public var messageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [MailAttachment]

    public init(bytes: [UInt8]) {
        let root = MIMEParser.parse(bytes)
        headers = root.headers
        subject = EncodedWords.decode(root.headers["Subject"] ?? "").trimmed()
        from = EmailAddress.parseList(root.headers["From"] ?? "")
        to = EmailAddress.parseList(root.headers["To"] ?? "")
        cc = EmailAddress.parseList(root.headers["Cc"] ?? "")
        replyTo = EmailAddress.parseList(root.headers["Reply-To"] ?? "")
        date = root.headers["Date"].flatMap(MailDate.parse)
        messageID = MessageIDs.parse(root.headers["Message-ID"] ?? "").first
        inReplyTo = MessageIDs.parse(root.headers["In-Reply-To"] ?? "").first
        references = MessageIDs.parse(root.headers["References"] ?? "")

        var collector = BodyCollector()
        collector.collect(root)
        textBody = collector.text.isEmpty ? nil : collector.text.joined(separator: "\n\n")
        htmlBody = collector.html.isEmpty ? nil : collector.html.joined(separator: "<hr>")
        attachments = collector.attachments
    }

    /// Attachments a person would want to save (not images embedded in the HTML).
    public var visibleAttachments: [MailAttachment] {
        attachments.filter { attachment in
            guard attachment.isInline, let cid = attachment.contentID, let html = htmlBody else { return true }
            return !html.contains("cid:\(cid)")
        }
    }

    /// Plain text for quoting and snippets.
    public var plainText: String {
        if let textBody, !textBody.trimmed().isEmpty { return textBody }
        if let htmlBody { return HTMLText.toPlainText(htmlBody) }
        return ""
    }

    public func snippet(maxLength: Int = 180) -> String {
        Self.makeSnippet(plainText, maxLength: maxLength)
    }

    static func makeSnippet(_ text: String, maxLength: Int) -> String {
        // Skip quoted reply lines so the snippet shows what is new.
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmed().hasPrefix(">") }
        let collapsed = lines.joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmed() + "…"
    }

    /// HTML with `cid:` images swapped for data URLs so the viewer can show them.
    public func htmlWithInlineImages() -> String? {
        guard var html = htmlBody else { return nil }
        for attachment in attachments {
            guard let cid = attachment.contentID, html.contains("cid:\(cid)") else { continue }
            let dataURL = "data:\(attachment.mimeType);base64,\(Data(attachment.data).base64EncodedString())"
            html = html.replacingOccurrences(of: "cid:\(cid)", with: dataURL)
        }
        return html
    }
}

private struct BodyCollector {
    var text: [String] = []
    var html: [String] = []
    var attachments: [MailAttachment] = []

    mutating func collect(_ part: MIMEPart) {
        let type = part.mimeType
        if type == "multipart/alternative" {
            collectAlternative(part)
            return
        }
        if type.hasPrefix("multipart/") {
            for child in part.parts { collect(child) }
            return
        }
        let dispositionType = part.disposition?.value ?? ""
        let isAttachment = dispositionType == "attachment"
        if !isAttachment && type == "text/plain" && part.filename == nil {
            text.append(part.decodedText)
        } else if !isAttachment && type == "text/html" && part.filename == nil {
            html.append(part.decodedText)
        } else {
            addAttachment(part)
        }
    }

    private mutating func collectAlternative(_ part: MIMEPart) {
        var bestText: String?
        var bestHTML: String?
        for child in part.parts {
            var sub = BodyCollector()
            sub.collect(child)
            if !sub.html.isEmpty { bestHTML = sub.html.joined(separator: "<hr>") }
            if !sub.text.isEmpty { bestText = sub.text.joined(separator: "\n\n") }
            for var attachment in sub.attachments {
                attachment.id = attachments.count
                attachments.append(attachment)
            }
        }
        if let bestText { text.append(bestText) }
        if let bestHTML { html.append(bestHTML) }
    }

    private mutating func addAttachment(_ part: MIMEPart) {
        let type = part.mimeType
        var name = part.filename
        if name == nil {
            switch type {
            case "message/rfc822": name = "Attached message.eml"
            case "text/calendar": name = "invite.ics"
            default:
                let ext = type.split(separator: "/").last.map(String.init) ?? "bin"
                name = "attachment.\(ext)"
            }
        }
        let isInline = (part.disposition?.value ?? "inline") != "attachment" && part.contentID != nil
        attachments.append(MailAttachment(
            id: attachments.count,
            filename: name ?? "attachment",
            mimeType: type,
            data: part.decodedBody,
            contentID: part.contentID,
            isInline: isInline
        ))
    }
}

public enum MessageIDs {
    /// Pulls every `<id>` out of a Message-ID, In-Reply-To or References header.
    public static func parse(_ raw: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let id = rest[rest.index(after: open)..<close].trimmed()
            if !id.isEmpty { ids.append(id) }
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            let bare = raw.trimmed()
            if !bare.isEmpty && !bare.contains(" ") { ids.append(bare) }
        }
        return ids
    }
}
