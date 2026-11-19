import XCTest
@testable import MailEngine

final class ParsingTests: XCTestCase {
    func testTokenizerHandlesFetchWithLiteralAndSection() throws {
        let raw = crlf("* 12 FETCH (UID 345 FLAGS (\\Seen \\Flagged) INTERNALDATE \"19-Nov-2026 14:44:45 +0100\" RFC822.SIZE 1200 BODY[HEADER.FIELDS (FROM SUBJECT)] {38}\nFrom: a@b.com\nSubject: Hi (there)\n\n)")
        let fetched = try XCTUnwrap(IMAPClient.parseFetch(raw))
        XCTAssertEqual(fetched.sequence, 12)
        XCTAssertEqual(fetched.uid, 345)
        XCTAssertEqual(fetched.flags, ["\\Seen", "\\Flagged"])
        XCTAssertEqual(fetched.size, 1200)
        XCTAssertEqual(String(decoding: fetched.header ?? [], as: UTF8.self), "From: a@b.com\r\nSubject: Hi (there)\r\n\r\n")
        let expected = MailDate.parse("Thu, 19 Nov 2026 14:44:45 +0100")
        XCTAssertEqual(fetched.internalDate, expected)
    }

    func testTokenizerParsesListAndNil() throws {
        let tokens = try IMAPTokenizer.parse(bytes(#"* LIST (\HasNoChildren \Sent) NIL "[Gmail]/Sent Mail""#))
        XCTAssertEqual(tokens.count, 5)
        XCTAssertEqual(tokens[3], .nil_)
        XCTAssertEqual(tokens[4].text, "[Gmail]/Sent Mail")
    }

    func testTrailingLiteralLength() {
        XCTAssertEqual(IMAPClient.trailingLiteralLength(bytes("* 1 FETCH (BODY[] {120}")), 120)
        XCTAssertEqual(IMAPClient.trailingLiteralLength(bytes("A1 APPEND x {5+}")), 5)
        XCTAssertNil(IMAPClient.trailingLiteralLength(bytes("* OK done }")))
    }

    func testIMAPSet() {
        XCTAssertEqual(IMAPSet.string(from: [5, 1, 2, 3, 7, 9, 10, 11]), "1:3,5,7,9:11")
        XCTAssertEqual(IMAPSet.string(from: [4]), "4")
        XCTAssertEqual(IMAPSet.string(from: []), "")
    }

    func testModifiedUTF7() {
        XCTAssertEqual(ModifiedUTF7.decode("Entw&APw-rfe"), "Entwürfe")
        XCTAssertEqual(ModifiedUTF7.encode("Entwürfe"), "Entw&APw-rfe")
        XCTAssertEqual(ModifiedUTF7.decode("Tom &- Jerry"), "Tom & Jerry")
        XCTAssertEqual(ModifiedUTF7.encode("Tom & Jerry"), "Tom &- Jerry")
        let japanese = "受信トレイ"
        XCTAssertEqual(ModifiedUTF7.decode(ModifiedUTF7.encode(japanese)), japanese)
    }

    func testEncodedWords() {
        XCTAssertEqual(EncodedWords.decode("=?UTF-8?B?w6l0w6k=?= =?UTF-8?Q?_caf=C3=A9?="), "été café")
        XCTAssertEqual(EncodedWords.decode("Re: =?iso-8859-1?q?Gr=FC=DFe?= aus Berlin"), "Re: Grüße aus Berlin")
        // A UTF-8 character split across two words.
        XCTAssertEqual(EncodedWords.decode("=?utf-8?B?4oKs?= =?utf-8?Q?=E2=82?= =?utf-8?Q?=AC?="), "€€")
        XCTAssertEqual(EncodedWords.decode("plain subject"), "plain subject")
        XCTAssertEqual(EncodedWords.decode("broken =?utf-8?x?abc?= stays"), "broken =?utf-8?x?abc?= stays")
    }

    func testAddressList() {
        let list = EmailAddress.parseList(#""Doe, Jane" <jane@x.com>, bob@y.com (Bob Smith), =?utf-8?q?J=C3=B6rg?= <j@z.de>, undisclosed-recipients:;"#)
        XCTAssertEqual(list, [
            EmailAddress(name: "Doe, Jane", address: "jane@x.com"),
            EmailAddress(name: "Bob Smith", address: "bob@y.com"),
            EmailAddress(name: "Jörg", address: "j@z.de"),
        ])
        XCTAssertEqual(EmailAddress.parseList("a@b.com; c@d.com").map(\.address), ["a@b.com", "c@d.com"])
        XCTAssertEqual(EmailAddress(name: "Doe, Jane", address: "j@x.com").headerValue, #""Doe, Jane" <j@x.com>"#)
        XCTAssertTrue(EmailAddress(address: "j@x.com").isValid)
        XCTAssertFalse(EmailAddress(address: "j@x").isValid)
        XCTAssertFalse(EmailAddress(address: "jx.com").isValid)
    }

    func testDates() throws {
        let a = try XCTUnwrap(MailDate.parse("Tue, 3 Feb 2026 09:05:00 -0800 (PST)"))
        let b = try XCTUnwrap(MailDate.parse("3 Feb 2026 17:05 GMT"))
        XCTAssertEqual(a, b)
        let c = try XCTUnwrap(MailDate.parseInternalDate(" 3-Feb-2026 17:05:00 +0000"))
        XCTAssertEqual(a, c)
        XCTAssertNil(MailDate.parse("not a date"))
    }

    func testRFC2231Parameters() {
        let p = HeaderValueWithParameters(parsing: "attachment; filename*0*=UTF-8''%E2%82%AC%20rate; filename*1=\" list.pdf\"")
        XCTAssertEqual(p.value, "attachment")
        XCTAssertEqual(p.parameters["filename"], "€ rate list.pdf")
        let q = HeaderValueWithParameters(parsing: #"text/plain; charset="UTF-8"; format=flowed"#)
        XCTAssertEqual(q.parameters["charset"], "UTF-8")
        XCTAssertEqual(q.parameters["format"], "flowed")
    }

    func testMultipartMessage() throws {
        let raw = crlf("""
        From: =?utf-8?q?Ren=C3=A9e?= <renee@example.com>
        To: me@example.com
        Subject: Report
        Date: Wed, 18 Nov 2026 10:00:00 +0000
        Message-ID: <abc@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="outer"

        This is a multi-part message.
        --outer
        Content-Type: multipart/related; boundary="rel"

        --rel
        Content-Type: multipart/alternative; boundary=alt

        --alt
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9 numbers are in. This line is long enough to wrap with a soft =
        break.
        > quoted
        --alt
        Content-Type: text/html; charset=utf-8

        <p>Caf&eacute; numbers <img src="cid:logo123"></p>
        --alt--
        --rel
        Content-Type: image/png
        Content-ID: <logo123>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --rel--
        --outer
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --outer--
        """)
        let message = ParsedMessage(bytes: raw)
        XCTAssertEqual(message.subject, "Report")
        XCTAssertEqual(message.from.first?.name, "Renée")
        XCTAssertEqual(message.messageID, "abc@example.com")
        XCTAssertEqual(message.textBody, "Café numbers are in. This line is long enough to wrap with a soft break.\r\n> quoted")
        XCTAssertTrue(message.htmlBody?.contains("cid:logo123") ?? false)
        XCTAssertEqual(message.attachments.count, 2)
        XCTAssertEqual(message.visibleAttachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(message.visibleAttachments.first?.data, bytes("%PDF-1.4\n"))
        XCTAssertTrue(message.htmlWithInlineImages()?.contains("data:image/png;base64,iVBORw0KGgo=") ?? false)
        XCTAssertEqual(message.snippet(), "Café numbers are in. This line is long enough to wrap with a soft break.")
    }

    func testLatin1PlainMessage() {
        var raw = bytes("Subject: test\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\n")
        raw += [0x47, 0x72, 0xFC, 0xDF, 0x65] // "Grüße"
        XCTAssertEqual(ParsedMessage(bytes: raw).textBody, "Grüße")
    }

    func testHTMLToText() {
        let html = "<html><head><style>p{color:red}</style></head><body><p>Hello&nbsp;there</p><div>Line&#33; &amp; more</div></body></html>"
        XCTAssertEqual(HTMLText.toPlainText(html), "Hello there\nLine! & more")
    }

    func testBuilderRoundTrip() throws {
        let attachment = OutgoingAttachment(filename: "Übersicht.txt", mimeType: "text/plain", data: bytes("hello"))
        let message = OutgoingMessage(
            from: EmailAddress(name: "Zoë Example", address: "zoe@example.com"),
            to: [EmailAddress(name: "Doe, Jane", address: "jane@example.com")],
            cc: [EmailAddress(address: "cc@example.com")],
            bcc: [EmailAddress(address: "secret@example.com")],
            subject: "Grüße from the café, a subject that is long enough to need more than one encoded word",
            textBody: "Line one\n.leading dot\nnon-ascii: 東京 = ok \nend",
            attachments: [attachment],
            inReplyTo: "parent@example.com",
            references: ["root@example.com", "parent@example.com"]
        )
        let built = MessageBuilder.build(message)
        let text = String(decoding: built, as: UTF8.self)
        XCTAssertFalse(text.contains("secret@example.com"), "Bcc must not leak into headers")
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "Only CRLF line endings")
        for line in text.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 998)
        }
        let parsed = ParsedMessage(bytes: built)
        XCTAssertEqual(parsed.subject, message.subject)
        XCTAssertEqual(parsed.from, [message.from])
        XCTAssertEqual(parsed.to, message.to)
        XCTAssertEqual(parsed.textBody, "Line one\r\n.leading dot\r\nnon-ascii: 東京 = ok \r\nend")
        XCTAssertEqual(parsed.attachments.first?.filename, "Übersicht.txt")
        XCTAssertEqual(parsed.attachments.first?.data, bytes("hello"))
        XCTAssertEqual(parsed.inReplyTo, "parent@example.com")
        XCTAssertEqual(parsed.references, ["root@example.com", "parent@example.com"])
        XCTAssertEqual(message.envelopeRecipients, ["jane@example.com", "cc@example.com", "secret@example.com"])
    }

    func testQuotedPrintableLongLine() {
        let long = String(repeating: "é", count: 60)
        let encoded = TextCodecs.encodeQuotedPrintable(long)
        for line in encoded.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.count, 76) }
        XCTAssertEqual(String(decoding: TextCodecs.decodeQuotedPrintable(Array(encoded.utf8)), as: UTF8.self), long)
    }

    func testDotStuffing() {
        let out = SMTPClient.dotStuff(bytes(".hidden\r\nok\r\n..two"))
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "..hidden\r\nok\r\n...two\r\n.\r\n")
    }

    func testMailboxRoles() {
        let id = UUID()
        func role(_ path: String, _ attrs: Set<String> = []) -> MailboxRole {
            MailboxRole.detect(path: path, name: path, delimiter: "/", attributes: attrs)
        }
        XCTAssertEqual(role("INBOX"), .inbox)
        XCTAssertEqual(role("[Gmail]/All Mail", ["\\all"]), .archive)
        XCTAssertEqual(role("Sent Items"), .sent)
        XCTAssertEqual(role("Bulk Mail"), .junk)
        XCTAssertEqual(role("Work/Clients"), .other)
        let box = MailboxInfo(accountID: id, path: "Work/Clients", name: "Work/Clients", delimiter: "/", role: .other)
        XCTAssertEqual(box.displayName, "Clients")
        XCTAssertEqual(box.depth, 1)
    }

    func testProviderMatching() {
        XCTAssertEqual(ProviderPreset.matching(email: "a@gmail.com")?.id, "gmail")
        XCTAssertEqual(ProviderPreset.matching(email: "a@me.com")?.id, "icloud")
        XCTAssertEqual(ProviderPreset.matching(email: "a@zohomail.eu")?.id, "zoho")
        XCTAssertNil(ProviderPreset.matching(email: "a@mycompany.com"))
        XCTAssertEqual(ProviderPreset.zohoHosts(region: .eu, organization: true).imap, "imappro.zoho.eu")
        XCTAssertEqual(ZohoRegion.guess(email: "x@zohomail.in"), .india)
    }

    func testAutoconfigParse() throws {
        let xml = """
        <clientConfig version="1.1"><emailProvider id="example.com">
        <incomingServer type="pop3"><hostname>pop.example.com</hostname><port>995</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
        <incomingServer type="imap"><hostname>imap.example.com</hostname><port>143</port><socketType>STARTTLS</socketType><username>%EMAILLOCALPART%</username></incomingServer>
        <incomingServer type="imap"><hostname>imap.example.com</hostname><port>993</port><socketType>SSL</socketType><username>%EMAILADDRESS%</username></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.example.com</hostname><port>587</port><socketType>STARTTLS</socketType><username>%EMAILADDRESS%</username></outgoingServer>
        </emailProvider></clientConfig>
        """
        let result = try XCTUnwrap(Autoconfig.parse(Data(xml.utf8), email: "me@example.com"))
        XCTAssertEqual(result.imap, ServerConfig(host: "imap.example.com", port: 993, security: .tls, username: "me@example.com"))
        XCTAssertEqual(result.smtp, ServerConfig(host: "smtp.example.com", port: 587, security: .startTLS, username: "me@example.com"))
    }
}
