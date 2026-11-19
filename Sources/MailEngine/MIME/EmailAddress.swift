import Foundation

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        let trimmedName = name?.trimmed()
        self.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        self.address = address.trimmed()
    }

    /// Name when there is one, otherwise the address.
    public var displayName: String { name ?? address }

    /// Header form, e.g. `"Doe, Jane" <jane@example.com>`, with encoded words for non-ASCII names.
    public var headerValue: String {
        guard let name, !name.isEmpty, name != address else { return address }
        if !name.isASCII {
            return "\(EncodedWords.encodeIfNeeded(name)) <\(address)>"
        }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.rangeOfCharacter(from: specials) != nil {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }

    /// Plain form for text fields: `Jane Doe <jane@example.com>`.
    public var editableValue: String {
        guard let name, name != address else { return address }
        return "\(name) <\(address)>"
    }

    public var isValid: Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return !address.contains(where: { $0 == " " || $0 == "<" || $0 == ">" || $0 == "," })
    }

    /// Parses an address-list header or what a person typed into a To field.
    /// Handles quoted names, comments, groups and encoded words.
    public static func parseList(_ raw: String) -> [EmailAddress] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var commentDepth = 0
        var escaped = false
        for ch in raw {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && (inQuotes || commentDepth > 0) {
                current.append(ch)
                escaped = true
                continue
            }
            if commentDepth > 0 {
                if ch == "(" { commentDepth += 1 }
                if ch == ")" { commentDepth -= 1 }
                current.append(ch)
                continue
            }
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "(" where !inQuotes:
                commentDepth += 1
                current.append(ch)
            case "<" where !inQuotes:
                angleDepth += 1
                current.append(ch)
            case ">" where !inQuotes:
                angleDepth = max(0, angleDepth - 1)
                current.append(ch)
            case ":" where !inQuotes && angleDepth == 0:
                // "Group name:" starts a group; drop the group name.
                current = ""
            case ",", ";":
                if inQuotes || angleDepth > 0 {
                    current.append(ch)
                } else {
                    entries.append(current)
                    current = ""
                }
            default:
                current.append(ch)
            }
        }
        entries.append(current)
        return entries.compactMap(parseSingle)
    }

    static func parseSingle(_ raw: String) -> EmailAddress? {
        let entry = raw.trimmed()
        guard !entry.isEmpty else { return nil }
        if let open = entry.lastIndex(of: "<"), let close = entry[open...].firstIndex(of: ">") {
            let address = String(entry[entry.index(after: open)..<close]).trimmed()
            var name = String(entry[entry.startIndex..<open]).trimmed()
            name = unquote(stripComments(name))
            guard !address.isEmpty else { return nil }
            return EmailAddress(name: EncodedWords.decode(name), address: address)
        }
        // Bare address, maybe with a comment holding the name: jane@example.com (Jane Doe)
        var comment: String?
        if let open = entry.firstIndex(of: "("), let close = entry.lastIndex(of: ")"), open < close {
            comment = String(entry[entry.index(after: open)..<close])
        }
        let address = stripComments(entry).trimmed()
        guard address.contains("@") else { return nil }
        return EmailAddress(name: comment.map { EncodedWords.decode($0) }, address: unquote(address))
    }

    private static func stripComments(_ s: String) -> String {
        var out = ""
        var depth = 0
        var inQuotes = false
        for ch in s {
            if ch == "\"" && depth == 0 { inQuotes.toggle() }
            if !inQuotes && ch == "(" { depth += 1; continue }
            if !inQuotes && ch == ")" && depth > 0 { depth -= 1; continue }
            if depth == 0 { out.append(ch) }
        }
        return out.trimmed()
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmed()
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 {
            t = String(t.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return t
    }
}

public extension Array where Element == EmailAddress {
    /// Comma-separated, wrapped so no header line passes 78 characters.
    func headerValue(fieldName: String) -> String {
        var lines: [String] = []
        var line = ""
        var lineLength = fieldName.count + 2
        for (index, address) in enumerated() {
            let piece = address.headerValue + (index < count - 1 ? "," : "")
            if !line.isEmpty && lineLength + piece.count + 1 > 78 {
                lines.append(line)
                line = piece
                lineLength = piece.count + 1
            } else {
                line += (line.isEmpty ? "" : " ") + piece
                lineLength += piece.count + 1
            }
        }
        lines.append(line)
        return lines.joined(separator: "\r\n ")
    }
}
