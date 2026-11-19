import Foundation

enum ASCII {
    static let cr: UInt8 = 13
    static let lf: UInt8 = 10
    static let space: UInt8 = 32
    static let tab: UInt8 = 9
    static let quote: UInt8 = 34
    static let backslash: UInt8 = 92
    static let openParen: UInt8 = 40
    static let closeParen: UInt8 = 41
    static let openBracket: UInt8 = 91
    static let closeBracket: UInt8 = 93
    static let openBrace: UInt8 = 123
    static let closeBrace: UInt8 = 125
    static let equals: UInt8 = 61
    static let crlf: [UInt8] = [13, 10]

    static func isDigit(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }
    static func isWhitespace(_ b: UInt8) -> Bool { b == space || b == tab || b == cr || b == lf }

    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    static func lowercase(_ b: UInt8) -> UInt8 { (b >= 65 && b <= 90) ? b + 32 : b }
}

extension Array where Element == UInt8 {
    init(ascii string: String) { self = Array(string.utf8) }

    func hasPrefixCaseInsensitive(_ prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        guard count >= p.count else { return false }
        for i in 0..<p.count where ASCII.lowercase(self[i]) != ASCII.lowercase(p[i]) { return false }
        return true
    }

    func trimmingWhitespace() -> [UInt8] {
        var start = startIndex
        var end = endIndex
        while start < end && ASCII.isWhitespace(self[start]) { start += 1 }
        while end > start && ASCII.isWhitespace(self[end - 1]) { end -= 1 }
        return Array(self[start..<end])
    }
}

extension String {
    var isASCII: Bool { utf8.allSatisfy { $0 < 128 } }

    /// Normalizes any line break style to CRLF.
    func normalizedToCRLF() -> String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}

extension StringProtocol {
    func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
