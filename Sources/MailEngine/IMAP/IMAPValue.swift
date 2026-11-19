import Foundation

/// One parsed IMAP data item.
public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string([UInt8])
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let s): return s
        case .string(let b): return String(decoding: b, as: UTF8.self)
        default: return nil
        }
    }

    public var bytes: [UInt8]? {
        switch self {
        case .string(let b): return b
        case .atom(let s): return Array(s.utf8)
        default: return nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    public var int: Int? { text.flatMap { Int($0) } }

    public var isNil: Bool {
        if case .nil_ = self { return true }
        return false
    }
}

enum IMAPTokenizerError: Error {
    case unexpectedEnd
    case badLiteral
}

/// Tokenizes a raw IMAP response, literals included in wire form (`{n}\r\n<bytes>`).
struct IMAPTokenizer {
    private let b: [UInt8]
    private var i: Int

    init(_ bytes: [UInt8], start: Int = 0) {
        b = bytes
        i = start
    }

    static func parse(_ bytes: [UInt8]) throws -> [IMAPValue] {
        var t = IMAPTokenizer(bytes)
        return try t.parseAll()
    }

    mutating func parseAll() throws -> [IMAPValue] {
        var out: [IMAPValue] = []
        while true {
            skipSpaces()
            if i >= b.count { break }
            out.append(try parseValue())
        }
        return out
    }

    private mutating func skipSpaces() {
        while i < b.count && (b[i] == ASCII.space || b[i] == ASCII.cr || b[i] == ASCII.lf) { i += 1 }
    }

    private mutating func parseValue() throws -> IMAPValue {
        guard i < b.count else { throw IMAPTokenizerError.unexpectedEnd }
        switch b[i] {
        case ASCII.openParen:
            i += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard i < b.count else { throw IMAPTokenizerError.unexpectedEnd }
                if b[i] == ASCII.closeParen {
                    i += 1
                    return .list(items)
                }
                items.append(try parseValue())
            }
        case ASCII.quote:
            i += 1
            var out: [UInt8] = []
            while i < b.count {
                let c = b[i]
                if c == ASCII.backslash && i + 1 < b.count {
                    out.append(b[i + 1])
                    i += 2
                    continue
                }
                if c == ASCII.quote {
                    i += 1
                    return .string(out)
                }
                out.append(c)
                i += 1
            }
            throw IMAPTokenizerError.unexpectedEnd
        case ASCII.openBrace:
            var j = i + 1
            var length = 0
            var sawDigit = false
            while j < b.count && ASCII.isDigit(b[j]) {
                length = length * 10 + Int(b[j] - 48)
                sawDigit = true
                j += 1
            }
            if j < b.count && b[j] == UInt8(ascii: "+") { j += 1 }
            guard sawDigit, j < b.count, b[j] == ASCII.closeBrace else { return parseAtom() }
            j += 1
            if j < b.count && b[j] == ASCII.cr { j += 1 }
            if j < b.count && b[j] == ASCII.lf { j += 1 }
            guard j + length <= b.count else { throw IMAPTokenizerError.badLiteral }
            let literal = Array(b[j..<(j + length)])
            i = j + length
            return .string(literal)
        default:
            return parseAtom()
        }
    }

    private mutating func parseAtom() -> IMAPValue {
        let start = i
        var bracketDepth = 0
        while i < b.count {
            let c = b[i]
            if c == ASCII.openBracket {
                bracketDepth += 1
            } else if c == ASCII.closeBracket {
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth == 0 && (c == ASCII.space || c == ASCII.openParen || c == ASCII.closeParen || c == ASCII.cr || c == ASCII.lf) {
                break
            }
            i += 1
        }
        if i == start {
            // A stray character such as an unmatched ")": consume it so parsing always advances.
            i += 1
            return .atom(String(decoding: [b[start]], as: UTF8.self))
        }
        let s = String(decoding: b[start..<i], as: UTF8.self)
        if s.uppercased() == "NIL" { return .nil_ }
        return .atom(s)
    }
}

/// Builds IMAP sequence sets such as `1:5,7,9:12`.
public enum IMAPSet {
    public static func string<S: Sequence>(from uids: S) -> String where S.Element == UInt32 {
        let sorted = Array(Set(uids)).sorted()
        guard var start = sorted.first else { return "" }
        var parts: [String] = []
        var prev = start
        for uid in sorted.dropFirst() {
            if uid == prev + 1 {
                prev = uid
                continue
            }
            parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
            start = uid
            prev = uid
        }
        parts.append(start == prev ? "\(start)" : "\(start):\(prev)")
        return parts.joined(separator: ",")
    }
}
