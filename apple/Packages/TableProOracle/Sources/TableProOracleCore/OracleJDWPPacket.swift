import Foundation

public struct OracleJDWPIDSizes: Sendable, Equatable {
    public var field: Int
    public var method: Int
    public var object: Int
    public var referenceType: Int
    public var frame: Int

    public init(field: Int, method: Int, object: Int, referenceType: Int, frame: Int) {
        self.field = field
        self.method = method
        self.object = object
        self.referenceType = referenceType
        self.frame = frame
    }

    // Measured on 23.26: 4, 4, 4, 4, 8.
    public static let oracle = OracleJDWPIDSizes(field: 4, method: 4, object: 4, referenceType: 4, frame: 8)

    // The peer chooses these; an ID wider than 8 bytes cannot be held, and a zero-width one is no ID.
    public static func validated(field: Int32, method: Int32, object: Int32, referenceType: Int32, frame: Int32) throws
        -> OracleJDWPIDSizes {
        let widths = [field, method, object, referenceType, frame].map(Int.init)
        guard widths.allSatisfy({ (1...8).contains($0) }) else { throw OracleJDWPError.malformedPacket }
        return OracleJDWPIDSizes(field: widths[0], method: widths[1], object: widths[2], referenceType: widths[3], frame: widths[4])
    }
}

public enum OracleJDWPIDKind: Sendable {
    case field
    case method
    case object
    case referenceType
    case frame
}

extension OracleJDWPIDSizes {
    func size(of kind: OracleJDWPIDKind) -> Int {
        switch kind {
        case .field: return field
        case .method: return method
        case .object: return object
        case .referenceType: return referenceType
        case .frame: return frame
        }
    }
}

public enum OracleJDWPError: Error, Sendable, Equatable {
    case truncated
    case malformedPacket
    case handshakeFailed
    case closed
    case reply(code: Int)
    case timedOut
    case unexpectedEvent
}

public struct OracleJDWPWriter: Sendable {
    public private(set) var data = Data()
    let sizes: OracleJDWPIDSizes

    public init(sizes: OracleJDWPIDSizes) {
        self.sizes = sizes
    }

    public mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    public mutating func i32(_ value: Int32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func i64(_ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    public mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        i32(Int32(bytes.count))
        data.append(contentsOf: bytes)
    }

    public mutating func id(_ value: UInt64, _ kind: OracleJDWPIDKind) {
        let width = min(max(sizes.size(of: kind), 1), 8)
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    public mutating func location(_ location: OracleJDWPLocation) {
        u8(location.typeTag)
        id(location.classID, .referenceType)
        id(location.methodID, .method)
        i64(location.index)
    }
}

public struct OracleJDWPReader: Sendable {
    private let bytes: [UInt8]
    private var offset = 0
    let sizes: OracleJDWPIDSizes

    public init(_ data: Data, sizes: OracleJDWPIDSizes) {
        self.bytes = Array(data)
        self.sizes = sizes
    }

    public var isAtEnd: Bool { offset >= bytes.count }

    public var remaining: Int { max(bytes.count - offset, 0) }

    // A count the peer sent, before a loop runs on it: never negative, and never more elements than the bytes left
    // could hold at `minimumSize` bytes each.
    public mutating func count(minimumSize: Int) throws -> Int {
        let count = Int(try i32())
        guard count >= 0, count <= remaining / max(minimumSize, 1) else { throw OracleJDWPError.malformedPacket }
        return count
    }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset + count <= bytes.count else { throw OracleJDWPError.truncated }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    public mutating func u8() throws -> UInt8 {
        try take(1).first ?? 0
    }

    public mutating func i32() throws -> Int32 {
        Int32(bitPattern: UInt32(try unsigned(4)))
    }

    public mutating func i64() throws -> Int64 {
        Int64(bitPattern: try unsigned(8))
    }

    public mutating func string() throws -> String {
        let length = Int(try i32())
        let slice = try take(length)
        return String(bytes: slice, encoding: .utf8) ?? String(bytes: slice, encoding: .isoLatin1) ?? ""
    }

    public mutating func id(_ kind: OracleJDWPIDKind) throws -> UInt64 {
        try unsigned(sizes.size(of: kind))
    }

    public mutating func location() throws -> OracleJDWPLocation {
        OracleJDWPLocation(
            typeTag: try u8(),
            classID: try id(.referenceType),
            methodID: try id(.method),
            index: try i64()
        )
    }

    public mutating func taggedValue() throws -> OracleJDWPValue {
        let tag = try u8()
        switch tag {
        case UInt8(ascii: "B"), UInt8(ascii: "Z"):
            return .primitive(tag: tag, bits: try unsigned(1))
        case UInt8(ascii: "C"), UInt8(ascii: "S"):
            return .primitive(tag: tag, bits: try unsigned(2))
        case UInt8(ascii: "I"), UInt8(ascii: "F"):
            return .primitive(tag: tag, bits: try unsigned(4))
        case UInt8(ascii: "J"), UInt8(ascii: "D"):
            return .primitive(tag: tag, bits: try unsigned(8))
        case UInt8(ascii: "V"):
            return .void
        default:
            return .object(tag: tag, id: try id(.object))
        }
    }

    private mutating func unsigned(_ width: Int) throws -> UInt64 {
        guard (0...8).contains(width) else { throw OracleJDWPError.malformedPacket }
        var value: UInt64 = 0
        for byte in try take(width) {
            value = value << 8 | UInt64(byte)
        }
        return value
    }
}

public struct OracleJDWPLocation: Sendable, Hashable {
    public let typeTag: UInt8
    public let classID: UInt64
    public let methodID: UInt64
    public let index: Int64

    public init(typeTag: UInt8 = 1, classID: UInt64, methodID: UInt64, index: Int64) {
        self.typeTag = typeTag
        self.classID = classID
        self.methodID = methodID
        self.index = index
    }
}

public enum OracleJDWPValue: Sendable, Equatable {
    case primitive(tag: UInt8, bits: UInt64)
    case object(tag: UInt8, id: UInt64)
    case void

    public static let stringTag = UInt8(ascii: "s")
    public static let objectTag = UInt8(ascii: "L")
    public static let arrayTag = UInt8(ascii: "[")

    public var objectID: UInt64? {
        if case .object(_, let id) = self { return id }
        return nil
    }
}

public enum OracleJDWPPacket: Sendable, Equatable {
    case command(id: UInt32, commandSet: UInt8, command: UInt8, data: Data)
    case reply(id: UInt32, errorCode: UInt16, data: Data)

    static let headerLength = 11
    static let replyFlag: UInt8 = 0x80
    // Nothing this debugger asks for comes near it; a larger length is a peer trying to make the app buffer it.
    public static let maximumLength = 16 * 1_024 * 1_024

    public static let handshake = Data("JDWP-Handshake".utf8)

    public var encoded: Data {
        var out = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
        }
        switch self {
        case let .command(id, commandSet, command, data):
            append32(UInt32(Self.headerLength + data.count))
            append32(id)
            out.append(0)
            out.append(commandSet)
            out.append(command)
            out.append(data)
        case let .reply(id, errorCode, data):
            append32(UInt32(Self.headerLength + data.count))
            append32(id)
            out.append(Self.replyFlag)
            withUnsafeBytes(of: errorCode.bigEndian) { out.append(contentsOf: $0) }
            out.append(data)
        }
        return out
    }

    // Nil until `bytes` holds a whole packet; the consumed length comes back with it.
    public static func decode(from bytes: Data) throws -> (packet: OracleJDWPPacket, length: Int)? {
        guard bytes.count >= headerLength else { return nil }
        let start = bytes.startIndex
        func u32(at offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(bytes[start + offset + $1]) }
        }
        let length = Int(u32(at: 0))
        guard length >= headerLength, length <= maximumLength else { throw OracleJDWPError.malformedPacket }
        guard bytes.count >= length else { return nil }
        let id = u32(at: 4)
        let flags = bytes[start + 8]
        let body = Data(bytes[(start + headerLength)..<(start + length)])
        if flags & replyFlag != 0 {
            let code = UInt16(bytes[start + 9]) << 8 | UInt16(bytes[start + 10])
            return (.reply(id: id, errorCode: code, data: body), length)
        }
        return (.command(id: id, commandSet: bytes[start + 9], command: bytes[start + 10], data: body), length)
    }
}

public struct OracleJDWPFrameBuffer: Sendable {
    private var pending = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        pending.append(data)
    }

    public mutating func nextPacket() throws -> OracleJDWPPacket? {
        guard let (packet, length) = try OracleJDWPPacket.decode(from: pending) else { return nil }
        pending = Data(pending.dropFirst(length))
        return packet
    }

    public mutating func take(_ count: Int) -> Data? {
        guard pending.count >= count else { return nil }
        let head = Data(pending.prefix(count))
        pending = Data(pending.dropFirst(count))
        return head
    }
}

public enum OracleJDWPCommand {
    public static let virtualMachine: UInt8 = 1
    public static let referenceType: UInt8 = 2
    public static let method: UInt8 = 6
    public static let objectReference: UInt8 = 9
    public static let stringReference: UInt8 = 10
    public static let threadReference: UInt8 = 11
    public static let arrayReference: UInt8 = 13
    public static let eventRequest: UInt8 = 15
    public static let stackFrame: UInt8 = 16
    public static let event: UInt8 = 64

    public static let version: UInt8 = 1
    public static let classesBySignature: UInt8 = 2
    public static let suspend: UInt8 = 8
    public static let resume: UInt8 = 9
    public static let idSizes: UInt8 = 7

    public static let signature: UInt8 = 1
    public static let fields: UInt8 = 4
    public static let methods: UInt8 = 5
    public static let staticValues: UInt8 = 6

    public static let lineTable: UInt8 = 1
    public static let variableTable: UInt8 = 2

    public static let objectReferenceType: UInt8 = 1
    public static let objectValues: UInt8 = 2

    public static let stringValue: UInt8 = 1
    public static let frames: UInt8 = 6
    public static let arrayLength: UInt8 = 1

    public static let set: UInt8 = 1
    public static let clear: UInt8 = 2

    public static let frameValues: UInt8 = 1
    public static let composite: UInt8 = 100
}

public enum OracleJDWPEventKind: UInt8, Sendable {
    case singleStep = 1
    case breakpoint = 2
    case classPrepare = 8
    case vmStart = 90
    case vmDeath = 99
}

public enum OracleJDWPEvent: Sendable, Equatable {
    case vmStart(thread: UInt64)
    case classPrepare(requestID: Int32, thread: UInt64, typeID: UInt64, signature: String)
    case breakpoint(requestID: Int32, thread: UInt64, location: OracleJDWPLocation)
    case singleStep(requestID: Int32, thread: UInt64, location: OracleJDWPLocation)
    case vmDeath
    case other(kind: UInt8)
}

public struct OracleJDWPEventSet: Sendable, Equatable {
    public let suspendPolicy: UInt8
    public let events: [OracleJDWPEvent]

    public static func decode(_ data: Data, sizes: OracleJDWPIDSizes) throws -> OracleJDWPEventSet {
        var reader = OracleJDWPReader(data, sizes: sizes)
        let policy = try reader.u8()
        // An event is at least its kind and its request id.
        let count = try reader.count(minimumSize: 5)
        var events: [OracleJDWPEvent] = []
        for _ in 0..<count {
            let kind = try reader.u8()
            let requestID = try reader.i32()
            switch OracleJDWPEventKind(rawValue: kind) {
            case .vmStart:
                events.append(.vmStart(thread: try reader.id(.object)))
            case .classPrepare:
                let thread = try reader.id(.object)
                _ = try reader.u8()
                let typeID = try reader.id(.referenceType)
                let signature = try reader.string()
                _ = try reader.i32()
                events.append(.classPrepare(requestID: requestID, thread: thread, typeID: typeID, signature: signature))
            case .breakpoint:
                events.append(.breakpoint(requestID: requestID, thread: try reader.id(.object), location: try reader.location()))
            case .singleStep:
                events.append(.singleStep(requestID: requestID, thread: try reader.id(.object), location: try reader.location()))
            case .vmDeath:
                events.append(.vmDeath)
            case nil:
                // The remaining events cannot be framed without knowing this kind's layout.
                events.append(.other(kind: kind))
                return OracleJDWPEventSet(suspendPolicy: policy, events: events)
            }
        }
        return OracleJDWPEventSet(suspendPolicy: policy, events: events)
    }
}

public enum OracleJDWPRequest {
    public static let suspendAll: UInt8 = 2
    static let modifierCount: UInt8 = 1
    static let modifierClassMatch: UInt8 = 5
    static let modifierLocationOnly: UInt8 = 7
    static let modifierStep: UInt8 = 10

    public enum StepDepth: Int32, Sendable {
        case into = 0
        case over = 1
        case out = 2
    }

    static let stepSizeLine: Int32 = 1

    public static func classPrepare(matching pattern: String, sizes: OracleJDWPIDSizes) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(OracleJDWPEventKind.classPrepare.rawValue)
        writer.u8(suspendAll)
        writer.i32(1)
        writer.u8(modifierClassMatch)
        writer.string(pattern)
        return writer.data
    }

    public static func breakpoint(at location: OracleJDWPLocation, sizes: OracleJDWPIDSizes) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(OracleJDWPEventKind.breakpoint.rawValue)
        writer.u8(suspendAll)
        writer.i32(1)
        writer.u8(modifierLocationOnly)
        writer.location(location)
        return writer.data
    }

    public static func step(thread: UInt64, depth: StepDepth, sizes: OracleJDWPIDSizes) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(OracleJDWPEventKind.singleStep.rawValue)
        writer.u8(suspendAll)
        writer.i32(1)
        writer.u8(modifierStep)
        writer.id(thread, .object)
        writer.i32(stepSizeLine)
        writer.i32(depth.rawValue)
        return writer.data
    }

    public static func clear(kind: OracleJDWPEventKind, requestID: Int32, sizes: OracleJDWPIDSizes) -> Data {
        var writer = OracleJDWPWriter(sizes: sizes)
        writer.u8(kind.rawValue)
        writer.i32(requestID)
        return writer.data
    }
}
