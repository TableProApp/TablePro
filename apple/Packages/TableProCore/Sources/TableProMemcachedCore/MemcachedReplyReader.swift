import Foundation

public enum MemcachedReplyShape: Sendable, Equatable {
    /// `VALUE` blocks closed by `END`, the reply to `get` and its kin.
    case values
    /// Lines closed by `END`, the reply to `stats` and `lru_crawler metadump`.
    case lines
    /// One status line such as `STORED`, `DELETED`, `VERSION 1.6.45` or a counter's new value.
    case status
}

public struct MemcachedValue: Equatable, Sendable {
    public let key: String
    public let flags: UInt32
    public let data: Data
    public let unique: UInt64?

    public init(key: String, flags: UInt32, data: Data, unique: UInt64? = nil) {
        self.key = key
        self.flags = flags
        self.data = data
        self.unique = unique
    }
}

public enum MemcachedReply: Equatable, Sendable {
    case values([MemcachedValue])
    /// `truncated` means the reader stopped at its line limit before `END`; the rest is still on the wire.
    case lines([String], truncated: Bool)
    case status(String)
}

public struct MemcachedServerError: Error, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case error = "ERROR"
        case clientError = "CLIENT_ERROR"
        case serverError = "SERVER_ERROR"
        case busy = "BUSY"
    }

    public let kind: Kind
    public let message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// `CLIENT_ERROR unauthenticated` is what a server started with an auth file says to any command before login.
    public var needsAuthentication: Bool {
        kind == .clientError && message.lowercased().contains("unauthenticated")
    }
}

public enum MemcachedProtocolError: Error, Equatable, Sendable {
    case malformedLine(String)
    case lineTooLong
}

/// Reads one reply from a byte stream fed in pieces. A reply can be large, so lines already read are kept rather
/// than scanned again when more bytes arrive.
public struct MemcachedReplyReader: Sendable {
    public let shape: MemcachedReplyShape
    private let lineLimit: Int
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var values: [MemcachedValue] = []
    private var lines: [String] = []
    private var pendingValue: (key: String, flags: UInt32, length: Int, unique: UInt64?)?

    private static let maximumLineLength = 64 * 1_024

    public init(shape: MemcachedReplyShape, lineLimit: Int = .max) {
        self.shape = shape
        self.lineLimit = lineLimit
    }

    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        if cursor > 1 << 16 {
            buffer.removeFirst(cursor)
            cursor = 0
        }
        buffer.append(contentsOf: bytes)
    }

    /// The reply once it is whole, or nil while more bytes are needed.
    public mutating func reply() throws -> MemcachedReply? {
        while true {
            if let pending = pendingValue {
                guard buffer.count - cursor >= pending.length + 2 else { return nil }
                let data = Data(buffer[cursor ..< cursor + pending.length])
                guard buffer[cursor + pending.length] == 0x0D, buffer[cursor + pending.length + 1] == 0x0A else {
                    throw MemcachedProtocolError.malformedLine("VALUE \(pending.key)")
                }
                cursor += pending.length + 2
                values.append(MemcachedValue(key: pending.key, flags: pending.flags, data: data, unique: pending.unique))
                pendingValue = nil
                continue
            }
            guard let line = try nextLine() else { return nil }
            if let error = Self.serverError(line) { throw error }
            switch shape {
            case .status:
                return .status(line)
            case .lines:
                if line == "END" { return .lines(lines, truncated: false) }
                if line == "OK", lines.isEmpty { continue }
                lines.append(line)
                if lines.count >= lineLimit { return .lines(lines, truncated: true) }
            case .values:
                if line == "END" { return .values(values) }
                pendingValue = try Self.valueHeader(line)
            }
        }
    }

    /// `lru_crawler metadump` ends its key lines with a bare LF and only `END` with CRLF, so a line ends at LF and
    /// a CR before it is dropped. Data blocks are read by length, never as lines.
    private mutating func nextLine() throws -> String? {
        guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else {
            if buffer.count - cursor > Self.maximumLineLength { throw MemcachedProtocolError.lineTooLong }
            return nil
        }
        let end = newline > cursor && buffer[newline - 1] == 0x0D ? newline - 1 : newline
        let line = MemcachedCommandParser.text(Array(buffer[cursor ..< end]))
        cursor = newline + 1
        return line
    }

    static func serverError(_ line: String) -> MemcachedServerError? {
        for kind in [MemcachedServerError.Kind.clientError, .serverError, .busy, .error] {
            let name = kind.rawValue
            if line == name { return MemcachedServerError(kind: kind, message: "") }
            if line.hasPrefix(name + " ") {
                return MemcachedServerError(kind: kind, message: String(line.dropFirst(name.count + 1)))
            }
        }
        return nil
    }

    private static func valueHeader(_ line: String) throws -> (key: String, flags: UInt32, length: Int, unique: UInt64?) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 4 || parts.count == 5, parts[0] == "VALUE",
              let flags = UInt32(parts[2]), let length = Int(parts[3]), length >= 0 else {
            throw MemcachedProtocolError.malformedLine(line)
        }
        let unique = parts.count == 5 ? UInt64(parts[4]) : nil
        return (String(parts[1]), flags, length, unique)
    }
}
