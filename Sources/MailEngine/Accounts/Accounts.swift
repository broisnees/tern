import Foundation

public struct ServerConfig: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity
    public var username: String

    public init(host: String, port: Int, security: ConnectionSecurity, username: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

public struct AccountConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// Name shown to recipients, e.g. "Jane Doe".
    public var senderName: String
    public var email: String
    public var providerID: String
    public var imap: ServerConfig
    public var smtp: ServerConfig
    public var signature: String
    public var colorIndex: Int

    public init(id: UUID = UUID(), senderName: String, email: String, providerID: String,
                imap: ServerConfig, smtp: ServerConfig, signature: String = "", colorIndex: Int = 0) {
        self.id = id
        self.senderName = senderName
        self.email = email
        self.providerID = providerID
        self.imap = imap
        self.smtp = smtp
        self.signature = signature
        self.colorIndex = colorIndex
    }

    public var sender: EmailAddress { EmailAddress(name: senderName, address: email) }
    public var provider: ProviderPreset? { ProviderPreset.byID(providerID) }
    public var isGmail: Bool { providerID == "gmail" || imap.host.lowercased() == "imap.gmail.com" }
}

public struct ProviderPreset: Identifiable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var imapHost: String
    public var imapPort: Int
    public var imapSecurity: ConnectionSecurity
    public var smtpHost: String
    public var smtpPort: Int
    public var smtpSecurity: ConnectionSecurity
    /// Email domains that belong to this provider, used to pick it automatically.
    public var domains: [String]
    /// What to type in the password field, in one or two sentences.
    public var passwordHelp: String
    public var passwordHelpURL: URL?
    public var passwordHelpLinkTitle: String?

    public func config(email: String, senderName: String) -> AccountConfig {
        AccountConfig(
            senderName: senderName,
            email: email,
            providerID: id,
            imap: ServerConfig(host: imapHost, port: imapPort, security: imapSecurity, username: email),
            smtp: ServerConfig(host: smtpHost, port: smtpPort, security: smtpSecurity, username: email)
        )
    }

    public static let gmail = ProviderPreset(
        id: "gmail", name: "Gmail",
        imapHost: "imap.gmail.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.gmail.com", smtpPort: 465, smtpSecurity: .tls,
        domains: ["gmail.com", "googlemail.com"],
        passwordHelp: "Use a Google app password, not your normal password. It needs 2-Step Verification turned on.",
        passwordHelpURL: URL(string: "https://myaccount.google.com/apppasswords"),
        passwordHelpLinkTitle: "Create an app password"
    )

    public static let icloud = ProviderPreset(
        id: "icloud", name: "iCloud",
        imapHost: "imap.mail.me.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .startTLS,
        domains: ["icloud.com", "me.com", "mac.com"],
        passwordHelp: "Use an app-specific password from your Apple Account, under Sign-In and Security.",
        passwordHelpURL: URL(string: "https://account.apple.com/account/manage"),
        passwordHelpLinkTitle: "Open Apple Account"
    )

    public static let zoho = ProviderPreset(
        id: "zoho", name: "Zoho Mail",
        imapHost: "imap.zoho.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.zoho.com", smtpPort: 465, smtpSecurity: .tls,
        domains: ["zoho.com", "zohomail.com", "zoho.eu", "zohomail.eu", "zoho.in", "zohomail.in", "zoho.com.au", "zoho.jp"],
        passwordHelp: "Turn on IMAP in Zoho Mail settings first. With two-factor sign-in on, use an app-specific password.",
        passwordHelpURL: URL(string: "https://accounts.zoho.com/home#security/app_password"),
        passwordHelpLinkTitle: "Create an app password"
    )

    public static let yahoo = ProviderPreset(
        id: "yahoo", name: "Yahoo Mail",
        imapHost: "imap.mail.yahoo.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.mail.yahoo.com", smtpPort: 465, smtpSecurity: .tls,
        domains: ["yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.fr", "yahoo.de", "yahoo.co.in", "yahoo.co.jp"],
        passwordHelp: "Use a Yahoo app password, from Account Security.",
        passwordHelpURL: URL(string: "https://login.yahoo.com/account/security"),
        passwordHelpLinkTitle: "Create an app password"
    )

    public static let fastmail = ProviderPreset(
        id: "fastmail", name: "Fastmail",
        imapHost: "imap.fastmail.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.fastmail.com", smtpPort: 465, smtpSecurity: .tls,
        domains: ["fastmail.com", "fastmail.fm"],
        passwordHelp: "Use an app password from Fastmail Settings, under Privacy & Security.",
        passwordHelpURL: URL(string: "https://app.fastmail.com/settings/security/apppasswords"),
        passwordHelpLinkTitle: "Create an app password"
    )

    public static let aol = ProviderPreset(
        id: "aol", name: "AOL",
        imapHost: "imap.aol.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "smtp.aol.com", smtpPort: 465, smtpSecurity: .tls,
        domains: ["aol.com"],
        passwordHelp: "Use an AOL app password, from Account Security.",
        passwordHelpURL: URL(string: "https://login.aol.com/account/security"),
        passwordHelpLinkTitle: "Create an app password"
    )

    public static let gmx = ProviderPreset(
        id: "gmx", name: "GMX",
        imapHost: "imap.gmx.com", imapPort: 993, imapSecurity: .tls,
        smtpHost: "mail.gmx.com", smtpPort: 587, smtpSecurity: .startTLS,
        domains: ["gmx.com", "gmx.us", "gmx.net", "gmx.de"],
        passwordHelp: "Turn on IMAP access in GMX settings, then use your GMX password.",
        passwordHelpURL: nil,
        passwordHelpLinkTitle: nil
    )

    public static let other = ProviderPreset(
        id: "other", name: "Other",
        imapHost: "", imapPort: 993, imapSecurity: .tls,
        smtpHost: "", smtpPort: 465, smtpSecurity: .tls,
        domains: [],
        passwordHelp: "Your provider's help pages list these server details.",
        passwordHelpURL: nil,
        passwordHelpLinkTitle: nil
    )

    public static let all: [ProviderPreset] = [gmail, icloud, zoho, yahoo, fastmail, aol, gmx, other]

    public static func byID(_ id: String) -> ProviderPreset? { all.first { $0.id == id } }

    public static func matching(email: String) -> ProviderPreset? {
        guard let domain = email.split(separator: "@").last?.lowercased() else { return nil }
        return all.first { $0.domains.contains(domain) }
    }

    /// Zoho runs separate data centers, and custom-domain (organization) accounts use different hosts.
    public static func zohoHosts(region: ZohoRegion, organization: Bool) -> (imap: String, smtp: String) {
        let suffix = region.domainSuffix
        return organization
            ? ("imappro.zoho.\(suffix)", "smtppro.zoho.\(suffix)")
            : ("imap.zoho.\(suffix)", "smtp.zoho.\(suffix)")
    }
}

public enum ZohoRegion: String, CaseIterable, Identifiable, Sendable {
    case us, eu, india, australia, japan

    public var id: String { rawValue }

    public var domainSuffix: String {
        switch self {
        case .us: return "com"
        case .eu: return "eu"
        case .india: return "in"
        case .australia: return "com.au"
        case .japan: return "jp"
        }
    }

    public var label: String {
        switch self {
        case .us: return "United States (zoho.com)"
        case .eu: return "Europe (zoho.eu)"
        case .india: return "India (zoho.in)"
        case .australia: return "Australia (zoho.com.au)"
        case .japan: return "Japan (zoho.jp)"
        }
    }

    public static func guess(email: String) -> ZohoRegion {
        let domain = email.split(separator: "@").last?.lowercased() ?? ""
        if domain.hasSuffix(".eu") { return .eu }
        if domain.hasSuffix(".in") { return .india }
        if domain.hasSuffix(".com.au") { return .australia }
        if domain.hasSuffix(".jp") { return .japan }
        return .us
    }
}
