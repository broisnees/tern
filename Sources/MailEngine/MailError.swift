import Foundation

/// Every failure the engine reports. `message` is written for a person reading an alert.
public enum MailError: Error, Equatable, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case timedOut
    case authenticationFailed(String)
    case commandFailed(String)
    case protocolError(String)
    case unsupported(String)
    case invalidInput(String)

    /// True when the socket is gone and a fresh connection might succeed.
    public var isConnectionLevel: Bool {
        switch self {
        case .connectionFailed, .connectionClosed, .timedOut, .protocolError: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .connectionFailed(let detail): return detail
        case .connectionClosed: return "The server closed the connection. Check your internet connection and try again."
        case .timedOut: return "The server took too long to answer. Check your internet connection and try again."
        case .authenticationFailed(let detail):
            let base = "The server rejected the email or password."
            return detail.isEmpty ? base : "\(base) Server said: \(detail)"
        case .commandFailed(let detail): return "The server refused the request: \(detail)"
        case .protocolError(let detail): return "The server sent a reply Tern couldn't read (\(detail))."
        case .unsupported(let detail): return detail
        case .invalidInput(let detail): return detail
        }
    }
}

extension MailError: LocalizedError {
    public var errorDescription: String? { message }
}
