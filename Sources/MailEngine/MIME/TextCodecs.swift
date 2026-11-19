import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Charset lookup and the transfer encodings mail uses.
public enum TextCodecs {
    public static func encoding(forCharset raw: String) -> String.Encoding? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        switch name {
        case "utf-8", "utf8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .ascii
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1": return .isoLatin1
        case "windows-1252", "cp1252", "x-cp1252": return .windowsCP1252
        case "iso-8859-2", "iso8859-2", "latin2": return .isoLatin2
        case "windows-1250", "cp1250": return .windowsCP1250
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1253", "cp1253": return .windowsCP1253
        case "windows-1254", "cp1254": return .windowsCP1254
        case "utf-16", "utf16": return .utf16
        case "utf-16be": return .utf16BigEndian
        case "utf-16le": return .utf16LittleEndian
        case "shift_jis", "shift-jis", "sjis", "x-sjis": return .shiftJIS
        case "iso-2022-jp": return .iso2022JP
        case "euc-jp": return .japaneseEUC
        default:
            #if canImport(Darwin)
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
            }
            #endif
            return nil
        }
    }

    /// Decodes text in the given charset, falling back to UTF-8 and then Windows-1252 so it never fails.
    public static func decode(_ bytes: [UInt8], charset: String?) -> String {
        if let charset, let enc = encoding(forCharset: charset), enc != .ascii,
           let s = String(bytes: bytes, encoding: enc) {
            return s
        }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        if let s = String(bytes: bytes, encoding: .windowsCP1252) { return s }
        return String(bytes: bytes, encoding: .isoLatin1) ?? String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Base64

    public static func decodeBase64(_ bytes: [UInt8]) -> [UInt8] {
        var clean: [UInt8] = []
        clean.reserveCapacity(bytes.count)
        for b in bytes {
            switch b {
            case 65...90, 97...122, 48...57, 43, 47: clean.append(b)
            case 45: clean.append(43) // base64url "-"
            case 95: clean.append(47) // base64url "_"
            default: continue
            }
        }
        if clean.count % 4 == 1 { clean.removeLast() }
        while clean.count % 4 != 0 { clean.append(61) }
        guard let data = Data(base64Encoded: Data(clean)) else { return [] }
        return [UInt8](data)
    }

    /// Base64 wrapped at 76 characters with CRLF.
    public static func encodeBase64Lines(_ bytes: [UInt8]) -> String {
        let encoded = Data(bytes).base64EncodedString()
        var lines: [Substring] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: 76, limitedBy: encoded.endIndex) ?? encoded.endIndex
            lines.append(encoded[index..<end])
            index = end
        }
        return lines.joined(separator: "\r\n")
    }

    // MARK: Quoted-printable

    public static func decodeQuotedPrintable(_ bytes: [UInt8], underscoreIsSpace: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            let c = bytes[i]
            if c == ASCII.equals {
                // Soft line break, possibly with trailing whitespace before it.
                var j = i + 1
                while j < n && (bytes[j] == ASCII.space || bytes[j] == ASCII.tab) { j += 1 }
                if j < n && bytes[j] == ASCII.cr && j + 1 < n && bytes[j + 1] == ASCII.lf { i = j + 2; continue }
                if j < n && bytes[j] == ASCII.lf { i = j + 1; continue }
                if j >= n { i = n; continue }
                if i + 2 < n, let hi = ASCII.hexValue(bytes[i + 1]), let lo = ASCII.hexValue(bytes[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                out.append(c)
                i += 1
            } else if underscoreIsSpace && c == UInt8(ascii: "_") {
                out.append(ASCII.space)
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    /// Quoted-printable for a text body. Lines stay under 76 characters.
    public static func encodeQuotedPrintable(_ text: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var output: [String] = []
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        for line in lines {
            let bytes = Array(line.utf8)
            var encodedLine: [UInt8] = []
            var lineLength = 0
            for (index, b) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                var token: [UInt8]
                if (b >= 33 && b <= 126 && b != ASCII.equals) || ((b == ASCII.space || b == ASCII.tab) && !isLast) {
                    token = [b]
                } else {
                    token = [ASCII.equals, hex[Int(b >> 4)], hex[Int(b & 0x0F)]]
                }
                // A leading "." is safe (SMTP dot-stuffing handles it), but "From " at line start is not touched either.
                if lineLength + token.count > 75 {
                    encodedLine += [ASCII.equals, ASCII.cr, ASCII.lf]
                    lineLength = 0
                }
                encodedLine += token
                lineLength += token.count
            }
            output.append(String(decoding: encodedLine, as: UTF8.self))
        }
        return output.joined(separator: "\r\n")
    }

    // MARK: Percent encoding (RFC 2231)

    static func percentDecode(_ s: String) -> [UInt8] {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = ASCII.hexValue(bytes[i + 1]), let lo = ASCII.hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }
}
