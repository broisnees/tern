import Foundation
import MailEngine

/// TCP + TLS through URLSessionStreamTask, which supports STARTTLS upgrades in place
/// (Network.framework connections can't be upgraded after they open).
final class StreamTransport: MailTransport, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let security: ConnectionSecurity
    private let lock = NSLock()
    private var task: URLSessionStreamTask?

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }

    static let factory: TransportFactory = { host, port, security in
        StreamTransport(host: host, port: port, security: security)
    }

    private var currentTask: URLSessionStreamTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func connect() async throws {
        let newTask = Self.session.streamTask(withHostName: host, port: port)
        lock.lock()
        task = newTask
        lock.unlock()
        newTask.resume()
        if security == .tls {
            newTask.startSecureConnection()
        }
    }

    func startTLS() async throws {
        guard let task = currentTask else { throw MailError.connectionClosed }
        task.startSecureConnection()
    }

    func write(_ bytes: [UInt8]) async throws {
        guard let task = currentTask else { throw MailError.connectionClosed }
        do {
            try await task.write(Data(bytes), timeout: 60)
        } catch {
            throw Self.map(error, host: host, port: port)
        }
    }

    func read() async throws -> [UInt8] {
        guard let task = currentTask else { throw MailError.connectionClosed }
        let result: (Data?, Bool)
        do {
            result = try await task.readData(ofMinLength: 1, maxLength: 256 * 1024, timeout: 120)
        } catch {
            throw Self.map(error, host: host, port: port)
        }
        if let data = result.0, !data.isEmpty {
            return [UInt8](data)
        }
        throw MailError.connectionClosed
    }

    func close() {
        lock.lock()
        let old = task
        task = nil
        lock.unlock()
        old?.cancel()
    }

    static func map(_ error: Error, host: String, port: Int) -> MailError {
        if let mailError = error as? MailError { return mailError }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .connectionFailed("Couldn't find the server \(host). Check the server name.")
            case NSURLErrorCannotConnectToHost:
                return .connectionFailed("Couldn't connect to \(host) on port \(port). Check the server name and port.")
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return .connectionFailed("You're offline. Tern will try again when the connection is back.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
                return .connectionFailed("Couldn't open a secure connection to \(host). Check the port and the security setting.")
            case NSURLErrorCancelled:
                return .connectionClosed
            default:
                break
            }
        }
        // Secure Transport errors (-9800 to -9899) mean the TLS handshake failed.
        if ns.code <= -9800 && ns.code >= -9899 {
            return .connectionFailed("Couldn't open a secure connection to \(host). Check the port and the security setting.")
        }
        return .connectionFailed("Couldn't reach \(host): \(ns.localizedDescription)")
    }
}
