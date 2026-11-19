import Foundation

public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plain connection upgraded with STARTTLS (SMTP 587, IMAP 143).
    case startTLS
    /// No encryption. Only for local test servers.
    case none
}

/// A byte pipe to a mail server. The macOS app backs it with URLSessionStreamTask;
/// tests back it with a plain socket.
public protocol MailTransport: AnyObject, Sendable {
    func connect() async throws
    /// Upgrade the open connection to TLS (STARTTLS).
    func startTLS() async throws
    func write(_ bytes: [UInt8]) async throws
    /// Returns at least one byte, or throws `MailError.connectionClosed` at end of stream.
    func read() async throws -> [UInt8]
    func close()
}

public typealias TransportFactory = @Sendable (_ host: String, _ port: Int, _ security: ConnectionSecurity) -> MailTransport

/// Line and byte reads on top of a transport.
final class BufferedConnection: @unchecked Sendable {
    let transport: MailTransport
    private var buffer: [UInt8] = []
    private var position = 0
    private var scanFrom = 0
    var trace: (@Sendable (String) -> Void)?

    init(transport: MailTransport) {
        self.transport = transport
    }

    /// Reads one line and returns it without the line break.
    func readLine() async throws -> [UInt8] {
        while true {
            var index = max(position, scanFrom)
            while index < buffer.count {
                if buffer[index] == ASCII.lf {
                    var end = index
                    if end > position && buffer[end - 1] == ASCII.cr { end -= 1 }
                    let line = Array(buffer[position..<end])
                    position = index + 1
                    scanFrom = position
                    compact()
                    trace?("S: " + String(decoding: line.prefix(300), as: UTF8.self))
                    return line
                }
                index += 1
            }
            scanFrom = buffer.count
            try await fill()
        }
    }

    func readBytes(_ count: Int) async throws -> [UInt8] {
        while buffer.count - position < count {
            try await fill()
        }
        let bytes = Array(buffer[position..<(position + count)])
        position += count
        scanFrom = position
        compact()
        return bytes
    }

    func write(_ bytes: [UInt8], redacted: Bool = false) async throws {
        if let trace {
            trace("C: " + (redacted ? "<redacted>" : String(decoding: bytes.prefix(300), as: UTF8.self)))
        }
        try await transport.write(bytes)
    }

    func write(_ string: String, redacted: Bool = false) async throws {
        try await write(Array(string.utf8), redacted: redacted)
    }

    /// Drops anything buffered. Call before a TLS upgrade.
    func discardBuffer() {
        buffer.removeAll()
        position = 0
        scanFrom = 0
    }

    private func fill() async throws {
        let chunk = try await transport.read()
        if chunk.isEmpty { throw MailError.connectionClosed }
        buffer.append(contentsOf: chunk)
    }

    private func compact() {
        if position > 64 * 1024 || position == buffer.count {
            buffer.removeFirst(position)
            scanFrom -= position
            position = 0
            if scanFrom < 0 { scanFrom = 0 }
        }
    }
}
