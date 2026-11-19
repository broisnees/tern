import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Looks up IMAP and SMTP settings for any domain, the way Thunderbird does:
/// the domain's own autoconfig file first, then Mozilla's public provider database.
public enum Autoconfig {
    public struct Result: Sendable, Equatable {
        public var imap: ServerConfig
        public var smtp: ServerConfig
    }

    public static func lookup(email: String, session: URLSession = .shared) async -> Result? {
        guard let domain = email.split(separator: "@").last.map(String.init)?.lowercased(), domain.contains(".") else { return nil }
        let encodedEmail = email.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? email
        let candidates = [
            "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(encodedEmail)",
            "https://autoconfig.thunderbird.net/v1.1/\(domain)",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = parse(data, email: email) else { continue }
            return result
        }
        return nil
    }

    /// Parses a Thunderbird `clientConfig` document.
    public static func parse(_ data: Data, email: String) -> Result? {
        let delegate = ConfigParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        let localPart = email.split(separator: "@").first.map(String.init) ?? email
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        func resolve(_ server: ConfigParser.Server?) -> ServerConfig? {
            guard let server, !server.hostname.isEmpty, let port = Int(server.port) else { return nil }
            let security: ConnectionSecurity
            switch server.socketType.uppercased() {
            case "SSL", "TLS": security = .tls
            case "STARTTLS": security = .startTLS
            default: security = .none
            }
            let username = server.username
                .replacingOccurrences(of: "%EMAILADDRESS%", with: email)
                .replacingOccurrences(of: "%EMAILLOCALPART%", with: localPart)
                .replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
            let host = server.hostname.replacingOccurrences(of: "%EMAILDOMAIN%", with: domain)
            return ServerConfig(host: host, port: port, security: security, username: username.isEmpty ? email : username)
        }
        // Prefer encrypted servers when the file lists several.
        func best(_ servers: [ConfigParser.Server]) -> ConfigParser.Server? {
            servers.first { $0.socketType.uppercased() == "SSL" } ??
                servers.first { $0.socketType.uppercased() == "STARTTLS" } ?? servers.first
        }
        guard let imap = resolve(best(delegate.incoming)), let smtp = resolve(best(delegate.outgoing)) else { return nil }
        return Result(imap: imap, smtp: smtp)
    }

    /// Settings most self-hosted providers use: imap.domain and smtp.domain.
    public static func guess(email: String) -> Result {
        let domain = email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        return Result(
            imap: ServerConfig(host: "imap.\(domain)", port: 993, security: .tls, username: email),
            smtp: ServerConfig(host: "smtp.\(domain)", port: 465, security: .tls, username: email)
        )
    }

    private final class ConfigParser: NSObject, XMLParserDelegate {
        struct Server {
            var hostname = ""
            var port = ""
            var socketType = ""
            var username = ""
        }

        var incoming: [Server] = []
        var outgoing: [Server] = []
        private var current: Server?
        private var currentKind: String?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            text = ""
            if elementName == "incomingServer" && attributeDict["type"] == "imap" {
                current = Server()
                currentKind = "imap"
            } else if elementName == "outgoingServer" && attributeDict["type"] == "smtp" {
                current = Server()
                currentKind = "smtp"
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let value = text.trimmed()
            switch elementName {
            case "hostname": current?.hostname = value
            case "port": current?.port = value
            case "socketType": current?.socketType = value
            case "username": current?.username = value
            case "incomingServer":
                if currentKind == "imap", let c = current { incoming.append(c) }
                current = nil
                currentKind = nil
            case "outgoingServer":
                if currentKind == "smtp", let c = current { outgoing.append(c) }
                current = nil
                currentKind = nil
            default: break
            }
            text = ""
        }
    }
}
