import Foundation

/// Small, dependency-free HTML helpers for snippets, quoting and plain-text display.
public enum HTMLText {
    public static func toPlainText(_ html: String) -> String {
        var s = html
        for tag in ["head", "style", "script", "title"] {
            s = removeBlocks(tag, from: s)
        }
        // Line breaks for block elements.
        let breakTags = ["<br", "</p", "</div", "</tr", "</li", "</h1", "</h2", "</h3", "</h4", "</table", "</blockquote"]
        for tag in breakTags {
            s = s.replacingOccurrences(of: tag, with: "\n" + tag, options: .caseInsensitive)
        }
        var out = ""
        out.reserveCapacity(s.count)
        var inTag = false
        for ch in s {
            if ch == "<" { inTag = true; continue }
            if ch == ">" && inTag { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        out = decodeEntities(out)
        // Collapse runs of blank lines and trailing spaces.
        let lines = out.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var blankRun = 0
        for line in lines {
            if line.isEmpty {
                blankRun += 1
                if blankRun > 1 { continue }
            } else {
                blankRun = 0
            }
            result.append(line)
        }
        return result.joined(separator: "\n").trimmed()
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Plain text as HTML with clickable links.
    public static func plainTextToHTML(_ text: String) -> String {
        var html = escape(text)
        let pattern = #"(https?://[^\s<>"]+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(html.startIndex..., in: html)
            html = regex.stringByReplacingMatches(in: html, range: range, withTemplate: "<a href=\"$1\">$1</a>")
        }
        return html
    }

    static func removeBlocks(_ tag: String, from html: String) -> String {
        var s = html
        while let open = s.range(of: "<\(tag)", options: .caseInsensitive) {
            if let close = s.range(of: "</\(tag)>", options: .caseInsensitive, range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        return s
    }

    static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "#39": "'", "zwnj": "", "zwj": "", "shy": "", "hellip": "…", "mdash": "—", "ndash": "–",
        "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™",
        "euro": "€", "pound": "£", "bull": "•", "middot": "·",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let name = String(s[s.index(after: i)..<semi])
                if let replacement = namedEntities[name.lowercased()] {
                    out += replacement
                    i = s.index(after: semi)
                    continue
                }
                if name.hasPrefix("#") {
                    let num = name.dropFirst()
                    let value = num.lowercased().hasPrefix("x") ? UInt32(num.dropFirst(), radix: 16) : UInt32(num)
                    if let value, let scalar = Unicode.Scalar(value) {
                        out.unicodeScalars.append(scalar)
                        i = s.index(after: semi)
                        continue
                    }
                }
            }
            out.append(s[i])
            i = s.index(after: i)
        }
        return out
    }
}
