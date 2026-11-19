import Foundation

/// Parses and formats the date forms mail uses (RFC 5322 headers, IMAP INTERNALDATE).
public enum MailDate {
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let zoneNames: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5 * 3600, "EDT": -4 * 3600,
        "CST": -6 * 3600, "CDT": -5 * 3600,
        "MST": -7 * 3600, "MDT": -6 * 3600,
        "PST": -8 * 3600, "PDT": -7 * 3600,
    ]

    private static var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// RFC 5322 date, e.g. `Tue, 19 Nov 2026 14:44:45 +0000 (UTC)`. Lenient about the usual variations.
    public static func parse(_ raw: String) -> Date? {
        var s = raw
        // Drop comments such as "(UTC)".
        while let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            s.removeSubrange(open...close)
        }
        if let comma = s.firstIndex(of: ",") { s = String(s[s.index(after: comma)...]) }
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }).map(String.init)
        guard tokens.count >= 4 else { return nil }
        // Some senders write "Nov 19 2026"; accept either order.
        var dayToken = tokens[0], monthToken = tokens[1]
        if Int(dayToken) == nil { swap(&dayToken, &monthToken) }
        guard let day = Int(dayToken),
              let monthIndex = months.firstIndex(of: String(monthToken.prefix(3)).lowercased()),
              var year = Int(tokens[2]) else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        let timeParts = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard timeParts.count >= 2 else { return nil }
        let offset = tokens.count >= 5 ? zoneOffset(tokens[4]) : 0
        return makeDate(year: year, month: monthIndex + 1, day: day,
                        hour: timeParts[0], minute: timeParts[1],
                        second: timeParts.count > 2 ? timeParts[2] : 0, offset: offset)
    }

    /// IMAP INTERNALDATE, e.g. `19-Nov-2026 14:44:45 +0000`.
    public static func parseInternalDate(_ raw: String) -> Date? {
        let tokens = raw.trimmed().split(separator: " ").map(String.init)
        guard tokens.count >= 2 else { return nil }
        let dateParts = tokens[0].split(separator: "-").map(String.init)
        guard dateParts.count == 3,
              let day = Int(dateParts[0]),
              let monthIndex = months.firstIndex(of: dateParts[1].lowercased()),
              let year = Int(dateParts[2]) else { return nil }
        let timeParts = tokens[1].split(separator: ":").compactMap { Int($0) }
        guard timeParts.count == 3 else { return nil }
        let offset = tokens.count >= 3 ? zoneOffset(tokens[2]) : 0
        return makeDate(year: year, month: monthIndex + 1, day: day,
                        hour: timeParts[0], minute: timeParts[1], second: timeParts[2], offset: offset)
    }

    public static func formatHeader(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    public static func formatInternalDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    private static func zoneOffset(_ token: String) -> Int {
        if let first = token.first, first == "+" || first == "-" {
            let digits = token.dropFirst().prefix(4)
            guard digits.count == 4, let value = Int(digits) else { return 0 }
            let seconds = (value / 100) * 3600 + (value % 100) * 60
            return first == "-" ? -seconds : seconds
        }
        return zoneNames[token.uppercased()] ?? 0
    }

    private static func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int) -> Date? {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = min(second, 59)
        guard let utc = utcCalendar.date(from: comps) else { return nil }
        return utc.addingTimeInterval(TimeInterval(-offset))
    }
}
