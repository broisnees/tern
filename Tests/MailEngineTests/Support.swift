import Foundation
@testable import MailEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Plain TCP to a local test server. No TLS.
final class SocketTransport: MailTransport, @unchecked Sendable {
    let host: String
    let port: Int
    private var fd: Int32 = -1

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    func connect() async throws {
        #if os(Linux)
        fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw MailError.connectionFailed("socket") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &address.sin_addr)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Linux)
                Glibc.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard result == 0 else { throw MailError.connectionFailed("connect failed") }
    }

    func startTLS() async throws {}

    func write(_ bytes: [UInt8]) async throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { throw MailError.connectionClosed }
            offset += n
        }
    }

    func read() async throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { throw MailError.connectionClosed }
        return Array(buffer[0..<n])
    }

    func close() {
        if fd >= 0 {
            #if os(Linux)
            Glibc.close(fd)
            #else
            Darwin.close(fd)
            #endif
            fd = -1
        }
    }
}

/// Plays back a scripted server: each `send` from the client must match the next expected line.
final class ScriptedTransport: MailTransport, @unchecked Sendable {
    private var pendingReads: [[UInt8]] = []
    private(set) var written: [String] = []
    private let respond: (String) -> String?

    init(greeting: String, respond: @escaping (String) -> String?) {
        pendingReads.append(Array(greeting.utf8))
        self.respond = respond
    }

    func connect() async throws {}
    func startTLS() async throws {}

    func write(_ bytes: [UInt8]) async throws {
        let text = String(decoding: bytes, as: UTF8.self)
        written.append(text)
        if let reply = respond(text) {
            pendingReads.append(Array(reply.utf8))
        }
    }

    func read() async throws -> [UInt8] {
        guard !pendingReads.isEmpty else { throw MailError.connectionClosed }
        return pendingReads.removeFirst()
    }

    func close() {}
}

func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }
func crlf(_ s: String) -> [UInt8] { Array(s.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
