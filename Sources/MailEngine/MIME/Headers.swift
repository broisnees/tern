import Foundation

/// An ordered, case-insensitive header list.
public struct MIMEHeaders: Sendable, Equatable {
    public private(set) var fields: [(name: String, value: String)] = []

    public init() {}

    public static func == (lhs: MIMEHeaders, rhs: MIMEHeaders) -> Bool {
        lhs.fields.map { "\($0.name):\($0.value)" } == rhs.fields.map { "\($0.name):\($0.value)" }
    }

    /// Parses a header block. Values are raw (encoded words left in place).
    public init(parsing bytes: [UInt8]) {
        var current: (name: String, value: [UInt8])?
        func flush() {
            if let c = current {
                fields.append((c.name, Self.decodeRawBytes(c.value)))
            }
            current = nil
        }
        for rawLine in bytes.split(separator: ASCII.lf, omittingEmptySubsequences: false) {
            var line = Array(rawLine)
            if line.last == ASCII.cr { line.removeLast() }
            if line.isEmpty { break } // blank line ends the header block
            if line[0] == ASCII.space || line[0] == ASCII.tab {
                current?.value += [ASCII.space] + line.trimmingWhitespace()
            } else if let colon = line.firstIndex(of: UInt8(ascii: ":")) {
                flush()
                let name = String(decoding: line[0..<colon], as: UTF8.self).trimmed()
                let value = Array(line[(colon + 1)...]).trimmingWhitespace()
                current = (name, value)
            }
        }
        flush()
    }

    public subscript(name: String) -> String? {
        fields.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public mutating func add(_ name: String, _ value: String) {
        fields.append((name, value))
    }

    /// Header bytes are usually ASCII, but raw UTF-8 (RFC 6532) and stray Latin-1 both occur.
    static func decodeRawBytes(_ bytes: [UInt8]) -> String {
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }
}

/// `type/subtype; key=value` headers such as Content-Type and Content-Disposition.
public struct HeaderValueWithParameters: Sendable, Equatable {
    public var value: String
    public var parameters: [String: String]

    public init(value: String, parameters: [String: String] = [:]) {
        self.value = value
        self.parameters = parameters
    }

    public init(parsing raw: String) {
        let pieces = Self.splitOutsideQuotes(raw, separator: ";")
        value = (pieces.first ?? "").trimmed().lowercased()
        var simple: [String: String] = [:]
        // RFC 2231 pieces: name -> [(index, encoded, value)]
        var extended: [String: [(Int, Bool, String)]] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[piece.startIndex..<eq].trimmed().lowercased()
            var val = piece[piece.index(after: eq)...].trimmed()
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            if key.contains("*") {
                let encoded = key.hasSuffix("*")
                if encoded { key.removeLast() }
                let parts = key.split(separator: "*", maxSplits: 1).map(String.init)
                let base = parts[0]
                let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                extended[base, default: []].append((index, encoded, val))
            } else {
                simple[key] = val
            }
        }
        for (base, segments) in extended {
            var charset: String?
            var bytes: [UInt8] = []
            for (position, segment) in segments.sorted(by: { $0.0 < $1.0 }).enumerated() {
                var text = segment.2
                if segment.1 {
                    if position == 0 {
                        // charset'language'value
                        let quoteParts = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if quoteParts.count == 3 {
                            charset = String(quoteParts[0])
                            text = String(quoteParts[2])
                        }
                    }
                    bytes += TextCodecs.percentDecode(text)
                } else {
                    bytes += Array(text.utf8)
                }
            }
            simple[base] = TextCodecs.decode(bytes, charset: charset ?? "utf-8")
        }
        parameters = simple
    }

    static func splitOutsideQuotes(_ s: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inQuotes {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" { inQuotes.toggle() }
            if ch == separator && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}

/// RFC 2047 encoded words: `=?utf-8?B?...?=`.
public enum EncodedWords {
    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let b = Array(input.utf8)
        var out = ""
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?
        var plainStart = 0
        var i = 0
        var lastWasEncoded = false

        func flushPending() {
            if !pendingBytes.isEmpty || pendingCharset != nil {
                out += TextCodecs.decode(pendingBytes, charset: pendingCharset)
            }
            pendingBytes = []
            pendingCharset = nil
        }

        while i < b.count {
            if b[i] == UInt8(ascii: "="), i + 1 < b.count, b[i + 1] == UInt8(ascii: "?"),
               let word = parseWord(b, at: i) {
                // Text between the previous encoded word and this one.
                let between = Array(b[plainStart..<i])
                let onlySpace = between.allSatisfy { ASCII.isWhitespace($0) }
                if !(lastWasEncoded && onlySpace) {
                    flushPending()
                    out += String(decoding: between, as: UTF8.self)
                }
                if let current = pendingCharset, current.lowercased() != word.charset.lowercased() {
                    flushPending()
                }
                pendingCharset = word.charset
                pendingBytes += word.bytes
                i = word.end
                plainStart = i
                lastWasEncoded = true
                continue
            }
            i += 1
        }
        flushPending()
        out += String(decoding: b[plainStart..<b.count], as: UTF8.self)
        return out
    }

    private static func parseWord(_ b: [UInt8], at start: Int) -> (charset: String, bytes: [UInt8], end: Int)? {
        var i = start + 2
        let charsetStart = i
        while i < b.count && b[i] != UInt8(ascii: "?") {
            if ASCII.isWhitespace(b[i]) { return nil }
            i += 1
        }
        guard i + 2 < b.count else { return nil }
        var charset = String(decoding: b[charsetStart..<i], as: UTF8.self)
        if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) }
        let mode = ASCII.lowercase(b[i + 1])
        guard mode == UInt8(ascii: "b") || mode == UInt8(ascii: "q"), b[i + 2] == UInt8(ascii: "?") else { return nil }
        i += 3
        let textStart = i
        while i + 1 < b.count && !(b[i] == UInt8(ascii: "?") && b[i + 1] == UInt8(ascii: "=")) {
            if b[i] == ASCII.space && mode == UInt8(ascii: "q") { return nil }
            i += 1
        }
        guard i + 1 < b.count else { return nil }
        let text = Array(b[textStart..<i])
        let bytes = mode == UInt8(ascii: "b")
            ? TextCodecs.decodeBase64(text)
            : TextCodecs.decodeQuotedPrintable(text, underscoreIsSpace: true)
        return (charset, bytes, i + 2)
    }

    /// Encodes a header value when it isn't plain ASCII. Long values are split into several words.
    public static func encodeIfNeeded(_ value: String) -> String {
        if value.isASCII { return value }
        var words: [String] = []
        var chunk = ""
        for ch in value {
            if (chunk + String(ch)).utf8.count > 45 {
                words.append(chunk)
                chunk = ""
            }
            chunk.append(ch)
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words
            .map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }
            .joined(separator: "\r\n ")
    }
}
