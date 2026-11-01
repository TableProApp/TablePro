import Foundation

public struct BoltVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: UInt8
    public let minor: UInt8

    public init(major: UInt8, minor: UInt8) {
        self.major = major
        self.minor = minor
    }

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: BoltVersion, rhs: BoltVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var separatesLogon: Bool { self >= BoltVersion(major: 5, minor: 1) }
    public var sendsBoltAgent: Bool { self >= BoltVersion(major: 5, minor: 3) }
    public var hasElementIds: Bool { major >= 5 }
}

public enum BoltHandshake {
    public static let magic: [UInt8] = [0x60, 0x60, 0xB0, 0x17]

    // Each proposal is [0, range, minor, major]: major.minor down to major.(minor - range).
    public static let proposals: [UInt8] = [
        0x00, 0x04, 0x04, 0x05,
        0x00, 0x02, 0x04, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00
    ]

    public static var request: Data { Data(magic + proposals) }

    public static func version(fromResponse bytes: [UInt8]) -> BoltVersion? {
        guard bytes.count == 4, bytes != [0, 0, 0, 0] else { return nil }
        return BoltVersion(major: bytes[3], minor: bytes[2])
    }
}

public enum BoltRequest: Equatable, Sendable {
    case hello(extra: [String: PackStreamValue])
    case logon(auth: [String: PackStreamValue])
    case run(query: String, parameters: [String: PackStreamValue], extra: [String: PackStreamValue])
    case pull(count: Int64)
    case discard
    case reset
    case goodbye

    public var structure: PackStreamValue {
        switch self {
        case .hello(let extra):
            return .structure(tag: 0x01, fields: [.map(extra)])
        case .logon(let auth):
            return .structure(tag: 0x6A, fields: [.map(auth)])
        case .run(let query, let parameters, let extra):
            return .structure(tag: 0x10, fields: [.string(query), .map(parameters), .map(extra)])
        case .pull(let count):
            return .structure(tag: 0x3F, fields: [.map(["n": .int(count)])])
        case .discard:
            return .structure(tag: 0x2F, fields: [.map(["n": .int(-1)])])
        case .reset:
            return .structure(tag: 0x0F, fields: [])
        case .goodbye:
            return .structure(tag: 0x02, fields: [])
        }
    }

    public var expectsResponse: Bool { self != .goodbye }

    public var framed: Data { BoltChunker.frame(PackStreamEncoder.encode(structure)) }
}

public enum BoltResponse: Equatable, Sendable {
    case success([String: PackStreamValue])
    case record([PackStreamValue])
    case ignored
    case failure(code: String, message: String)

    public static func decode(_ message: Data) throws -> BoltResponse {
        guard case .structure(let tag, let fields) = try PackStreamDecoder.decode(message) else {
            throw BoltProtocolError.unexpectedMessage("not a structure")
        }
        switch tag {
        case 0x70:
            return .success(fields.first?.mapValue ?? [:])
        case 0x71:
            return .record(fields.first?.listValue ?? [])
        case 0x7E:
            return .ignored
        case 0x7F:
            let metadata = fields.first?.mapValue ?? [:]
            let code = metadata["code"]?.stringValue ?? metadata["neo4j_code"]?.stringValue ?? ""
            return .failure(code: code, message: metadata["message"]?.stringValue ?? "")
        default:
            throw BoltProtocolError.unexpectedMessage(String(format: "tag 0x%02X", tag))
        }
    }
}

public enum BoltProtocolError: Error, Equatable, Sendable, LocalizedError {
    case unexpectedMessage(String)
    case unsupportedServer
    case chunkTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .unexpectedMessage(let detail):
            return String(format: String(localized: "The server sent a message this client does not understand (%@)."), detail)
        case .unsupportedServer:
            return String(localized: "The server does not speak Bolt 4.2 to 5.4. Neo4j 4.2 or later is required.")
        case .chunkTooLarge(let size):
            return String(format: String(localized: "The server sent a %d-byte message, which is over the limit."), size)
        }
    }
}

public enum BoltChunker {
    public static let maximumChunkSize = Int(UInt16.max)

    public static func frame(_ message: Data) -> Data {
        var framed = Data()
        framed.reserveCapacity(message.count + 4)
        var offset = message.startIndex
        while offset < message.endIndex {
            let end = min(offset + maximumChunkSize, message.endIndex)
            let size = UInt16(end - offset)
            framed.append(UInt8(size >> 8))
            framed.append(UInt8(size & 0xFF))
            framed.append(message[offset ..< end])
            offset = end
        }
        framed.append(contentsOf: [0x00, 0x00])
        return framed
    }
}

// A zero-size chunk with nothing before it is a NOOP keep-alive, not an empty message.
public struct BoltDechunker: Sendable {
    public static let maximumMessageSize = 512 * 1_024 * 1_024

    private var buffer: [UInt8] = []
    private var cursor = 0
    private var message = Data()

    public init() {}

    public mutating func append<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        if cursor > 0, cursor >= buffer.count / 2 {
            buffer.removeFirst(cursor)
            cursor = 0
        }
        buffer.append(contentsOf: bytes)
    }

    public mutating func nextMessage() throws -> Data? {
        while buffer.count - cursor >= 2 {
            let size = Int(buffer[cursor]) << 8 | Int(buffer[cursor + 1])
            if size == 0 {
                cursor += 2
                guard !message.isEmpty else { continue }
                defer { message = Data() }
                return message
            }
            guard buffer.count - cursor >= 2 + size else { return nil }
            message.append(contentsOf: buffer[(cursor + 2) ..< (cursor + 2 + size)])
            cursor += 2 + size
            guard message.count <= Self.maximumMessageSize else {
                throw BoltProtocolError.chunkTooLarge(message.count)
            }
        }
        return nil
    }
}
