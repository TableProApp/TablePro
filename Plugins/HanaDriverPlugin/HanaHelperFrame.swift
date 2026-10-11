import Foundation

enum HanaHelperOpcode: UInt8, Sendable {
    case open = 1
    case connect = 2
    case execute = 3
    case explain = 4
    case ping = 5
    case cancel = 6
    case close = 7
}

enum HanaHelperFrameError: Error, Equatable, Sendable {
    case truncatedHeader(receivedByteCount: Int)
    case truncatedBody(expectedByteCount: Int, receivedByteCount: Int)
    case requestTooLarge(byteCount: Int)
    case frameTooLarge(byteCount: Int, limit: Int)
    case unknownStatus(UInt8)
    case unexpectedHandshake
    case incompatibleProtocol(Int)
    case unusableForcedSeverGrace
    case unexpectedReply(id: UInt64)

    var message: String {
        switch self {
        case .truncatedHeader(let received):
            return "the helper ended a frame header after \(received) of \(HanaHelperFrameHeader.byteCount) bytes"
        case .truncatedBody(let expected, let received):
            return "the helper ended a frame body after \(received) of \(expected) bytes"
        case .requestTooLarge(let byteCount):
            return "the request is \(byteCount) bytes, over the \(HanaHelperRequest.maximumBodyLength)-byte limit"
        case .frameTooLarge(let byteCount, let limit):
            return "the helper announced a \(byteCount)-byte frame, over the \(limit)-byte limit"
        case .unknownStatus(let status):
            return "the helper answered with unknown status \(status)"
        case .unexpectedHandshake:
            return "the helper did not open with its protocol handshake"
        case .incompatibleProtocol(let version):
            return "incompatible helper protocol \(version)"
        case .unusableForcedSeverGrace:
            let accepted = HanaHelperHandshake.acceptedForcedSeverGraceSeconds
            return "incompatible helper: its handshake names no forcedSeverGraceSeconds from "
                + "\(accepted.lowerBound) to \(accepted.upperBound)"
        case .unexpectedReply(let id):
            return "the helper answered frame \(id), which no call is waiting for"
        }
    }

    var failure: HanaBridgeFailure {
        HanaBridgeFailure(kind: .internalFailure, message: message)
    }
}

struct HanaHelperFrameHeader: Equatable, Sendable {
    static let byteCount = 13

    let bodyLength: UInt32
    let id: UInt64
    let code: UInt8

    init(bodyLength: UInt32, id: UInt64, code: UInt8) {
        self.bodyLength = bodyLength
        self.id = id
        self.code = code
    }

    init(decoding bytes: Data) throws {
        guard bytes.count == Self.byteCount else {
            throw HanaHelperFrameError.truncatedHeader(receivedByteCount: bytes.count)
        }
        let octets = [UInt8](bytes)
        bodyLength = octets[0..<4].reduce(0) { $0 << 8 | UInt32($1) }
        id = octets[4..<12].reduce(0) { $0 << 8 | UInt64($1) }
        code = octets[12]
    }

    var encoded: Data {
        var bytes = Data(capacity: Self.byteCount)
        withUnsafeBytes(of: bodyLength.bigEndian) { bytes.append(contentsOf: $0) }
        withUnsafeBytes(of: id.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(code)
        return bytes
    }
}

struct HanaHelperRequest: Sendable {
    static let maximumBodyLength = 1 << 30

    let header: HanaHelperFrameHeader
    let body: Data

    init(id: UInt64, opcode: HanaHelperOpcode, body: Data) throws {
        guard body.count <= Self.maximumBodyLength else {
            throw HanaHelperFrameError.requestTooLarge(byteCount: body.count)
        }
        header = HanaHelperFrameHeader(bodyLength: UInt32(body.count), id: id, code: opcode.rawValue)
        self.body = body
    }

    var encoded: Data {
        header.encoded + body
    }
}

enum HanaHelperReply: Equatable, Sendable {
    case success(Data)
    case failure(HanaBridgeFailure)

    static let maximumBodyLength = Int(Int32.max)

    private static let successStatus: UInt8 = 0
    private static let failureStatus: UInt8 = 1

    init(status: UInt8, body: Data) throws {
        switch status {
        case Self.successStatus:
            self = .success(body)
        case Self.failureStatus:
            self = .failure(HanaBridgeFailure.decoded(from: body))
        default:
            throw HanaHelperFrameError.unknownStatus(status)
        }
    }

    var result: Result<Data, HanaBridgeFailure> {
        switch self {
        case .success(let body): return .success(body)
        case .failure(let failure): return .failure(failure)
        }
    }
}

struct HanaHelperGreeting: Equatable, Sendable {
    let forcedSeverGrace: TimeInterval
}

enum HanaHelperHandshake {
    static let protocolVersion = 1
    static let frameID: UInt64 = 0
    static let maximumBodyLength = 4_096
    static let acceptedForcedSeverGraceSeconds = 1...3_600

    private static let successStatus: UInt8 = 0

    private struct Greeting: Decodable {
        private enum CodingKeys: String, CodingKey {
            case version = "protocol"
            case forcedSeverGraceSeconds
        }

        let version: Int
        let forcedSeverGraceSeconds: Int?
    }

    static func greeting(from header: HanaHelperFrameHeader, body: Data) throws -> HanaHelperGreeting {
        guard header.id == frameID,
              header.code == successStatus,
              let greeting = try? JSONDecoder().decode(Greeting.self, from: body)
        else {
            throw HanaHelperFrameError.unexpectedHandshake
        }
        guard greeting.version == protocolVersion else {
            throw HanaHelperFrameError.incompatibleProtocol(greeting.version)
        }
        guard let seconds = greeting.forcedSeverGraceSeconds, acceptedForcedSeverGraceSeconds.contains(seconds) else {
            throw HanaHelperFrameError.unusableForcedSeverGrace
        }
        return HanaHelperGreeting(forcedSeverGrace: TimeInterval(seconds))
    }
}
