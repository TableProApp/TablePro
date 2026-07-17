import Foundation

enum MessageKind: UInt8 {
    case assign = 1
    case reassign = 2
    case connect = 3
    case reconnect = 4
    case start = 5
    case cont = 6
    case abort = 7
    case logoff = 8
    case test = 9
    case config = 10
    case authMethods = 11
    case sso = 12
    case elicit = 13
}

struct LanMessage {
    static let headerLength = 52
    static let versionByte: UInt8 = 3
    static let requestClass: UInt8 = 1
    static let responseClass: UInt8 = 2
    static let encryptedBodyFlag: UInt8 = 0x80
    static let charsetUnnegotiated: UInt8 = 0xFF

    var messageClass: UInt8
    var kind: UInt8
    var byteVar: UInt8
    var correlationTag: UInt32
    var sessionNumber: UInt32
    var authentication: [UInt8]
    var requestNumber: UInt32
    var unionGTW: UInt8
    var hostCharSet: UInt8
    var body: [UInt8]

    var isBodyEncrypted: Bool { messageClass & LanMessage.encryptedBodyFlag != 0 }
    var trueClass: UInt8 { messageClass & 0x7F }
    var inTransaction: Bool { byteVar & 0x01 != 0 }

    init(
        kind: MessageKind,
        body: [UInt8],
        sessionNumber: UInt32 = 0,
        requestNumber: UInt32 = 0,
        correlationTag: UInt32 = 0,
        byteVar: UInt8 = 7,
        authentication: [UInt8] = [UInt8](repeating: 0, count: 8),
        hostCharSet: UInt8 = LanMessage.charsetUnnegotiated,
        unionGTW: UInt8 = 0,
        encrypted: Bool = false
    ) {
        self.messageClass = LanMessage.requestClass | (encrypted ? LanMessage.encryptedBodyFlag : 0)
        self.kind = kind.rawValue
        self.byteVar = byteVar
        self.correlationTag = correlationTag
        self.sessionNumber = sessionNumber
        self.authentication = authentication
        self.requestNumber = requestNumber
        self.unionGTW = unionGTW
        self.hostCharSet = hostCharSet
        self.body = body
    }

    private init(header: [UInt8], body: [UInt8]) {
        messageClass = header[1]
        kind = header[2]
        byteVar = header[5]
        correlationTag = LanMessage.readU32(header, 16)
        sessionNumber = LanMessage.readU32(header, 20)
        authentication = Array(header[24..<32])
        requestNumber = LanMessage.readU32(header, 32)
        unionGTW = header[36]
        hostCharSet = header[37]
        self.body = body
    }

    func encoded() -> [UInt8] {
        let bodyLength = UInt32(body.count)
        var header = [UInt8](repeating: 0, count: LanMessage.headerLength)
        header[0] = LanMessage.versionByte
        header[1] = messageClass
        header[2] = kind
        header[3] = UInt8((bodyLength >> 24) & 0xFF)
        header[4] = UInt8((bodyLength >> 16) & 0xFF)
        header[5] = byteVar
        header[8] = UInt8((bodyLength >> 8) & 0xFF)
        header[9] = UInt8(bodyLength & 0xFF)
        LanMessage.writeU32(&header, 16, correlationTag)
        LanMessage.writeU32(&header, 20, sessionNumber)
        for i in 0..<8 { header[24 + i] = i < authentication.count ? authentication[i] : 0 }
        LanMessage.writeU32(&header, 32, requestNumber)
        header[36] = unionGTW
        header[37] = hostCharSet
        return header + body
    }

    static func bodyLength(fromHeader header: [UInt8]) -> Int {
        let high = Int(readU16(header, 3))
        let low = Int(readU16(header, 8))
        return (high << 16) | low
    }

    static func decode(header: [UInt8], body: [UInt8]) -> LanMessage {
        LanMessage(header: header, body: body)
    }

    private static func readU16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func readU32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
            | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func writeU32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        bytes[at] = UInt8((value >> 24) & 0xFF)
        bytes[at + 1] = UInt8((value >> 16) & 0xFF)
        bytes[at + 2] = UInt8((value >> 8) & 0xFF)
        bytes[at + 3] = UInt8(value & 0xFF)
    }
}
