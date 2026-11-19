import AppKit
import MailEngine
import SwiftUI

enum Theme {
    /// Teal 700 (#0F766E). White text on it measures 5.5:1, so it works on filled buttons in both modes.
    static let brand = Color(red: 15 / 255, green: 118 / 255, blue: 110 / 255)

    /// Fills for avatars and account dots. Each passes 4.5:1 against white initials.
    static let palette: [Color] = [
        Color(red: 0.06, green: 0.46, blue: 0.43), // teal 700
        Color(red: 0.11, green: 0.31, blue: 0.85), // blue 700
        Color(red: 0.43, green: 0.16, blue: 0.85), // violet 700
        Color(red: 0.75, green: 0.09, blue: 0.36), // pink 700
        Color(red: 0.71, green: 0.33, blue: 0.04), // amber 700
        Color(red: 0.02, green: 0.47, blue: 0.34), // emerald 700
        Color(red: 0.26, green: 0.22, blue: 0.79), // indigo 700
        Color(red: 0.28, green: 0.33, blue: 0.41), // slate 600
    ]

    static func color(for key: String) -> Color {
        var hash: UInt32 = 2166136261
        for byte in key.lowercased().utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return palette[Int(hash % UInt32(palette.count))]
    }

    static func accountColor(_ index: Int) -> Color {
        palette[((index % palette.count) + palette.count) % palette.count]
    }
}

@MainActor
struct Avatar: View {
    let address: EmailAddress?
    var size: CGFloat = 32

    private var initials: String {
        guard let address else { return "?" }
        let source = address.name ?? address.address
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "@" })
            .filter { $0.first?.isLetter ?? false }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.color(for: address?.address ?? "")))
            .accessibilityHidden(true)
    }
}

enum DateText {
    /// "3:42 PM" today, "Yesterday", "Nov 3" this year, otherwise "11/3/24".
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
    }
}

extension MailboxRole {
    var symbol: String {
        switch self {
        case .inbox: return "tray"
        case .flagged: return "star"
        case .important: return "bookmark"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .other: return "folder"
        }
    }

    /// Unread badges only where unread means "needs attention".
    var showsUnreadBadge: Bool { self == .inbox || self == .other || self == .important }
}

extension MailAttachment {
    var symbol: String {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type == "application/pdf" { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type == "text/calendar" { return "calendar" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.hasPrefix("video/") { return "film" }
        if type == "message/rfc822" { return "envelope" }
        return "doc"
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
}

@MainActor
struct BannerView: View {
    let banner: Banner
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? Color.orange : Theme.brand)
            Text(banner.text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

/// Lets menu commands know the mail window (not a compose window) is in front.
struct MainWindowKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var isMainWindow: Bool? {
        get { self[MainWindowKey.self] }
        set { self[MainWindowKey.self] = newValue }
    }
}

enum KeyFocus {
    /// True while the cursor is in a text field, so shortcuts don't fire mid-typing.
    @MainActor static var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }
}
