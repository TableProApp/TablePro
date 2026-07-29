import Foundation

enum ParcelFlavor: UInt16 {
    case request = 1
    case response = 4
    case success = 8
    case failure = 9
    case record = 10
    case endStatement = 11
    case endRequest = 12
    case logoff = 37
    case config = 42
    case configRsp = 43
    case error = 49
    case dataInfo = 71
    case prepInfo = 86
    case indicRequest = 69
    case options = 85
    case connect = 88
    case lsn = 89
    case assign = 100
    case assignRsp = 101
    case prepInfoX = 125
    case ssoResponse = 134
    case dataInfoX = 146
    case bigResponse = 153
    case errorInfo = 164
    case gtwConfig = 165
    case clientConfig = 166
    case authMech = 167
    case statementInfo = 169
    case statementInfoEnd = 170
    case statementError = 192
    case statementStatus = 205
}

struct Parcel {
    static let alternateFlag: UInt16 = 0x8000
    static let standardHeaderLength = 4
    static let alternateHeaderLength = 8
    static let standardMaxTotal = 0xFFFF

    var flavor: UInt16
    var body: [UInt8]

    init(flavor: UInt16, body: [UInt8] = []) {
        self.flavor = flavor
        self.body = body
    }

    init(_ flavor: ParcelFlavor, body: [UInt8] = []) {
        self.init(flavor: flavor.rawValue, body: body)
    }

    var knownFlavor: ParcelFlavor? { ParcelFlavor(rawValue: flavor) }

    func encoded() -> [UInt8] {
        let standardTotal = Parcel.standardHeaderLength + body.count
        if standardTotal <= Parcel.standardMaxTotal {
            var writer = ByteWriter()
            writer.u16(flavor)
            writer.u16(UInt16(standardTotal))
            writer.raw(body)
            return writer.bytes
        }
        let total = UInt32(Parcel.alternateHeaderLength + body.count)
        var writer = ByteWriter()
        writer.u16(flavor | Parcel.alternateFlag)
        writer.u16(0)
        writer.u32(total)
        writer.raw(body)
        return writer.bytes
    }

    static func encodeAll(_ parcels: [Parcel]) -> [UInt8] {
        parcels.flatMap { $0.encoded() }
    }

    static func decodeAll(_ bytes: [UInt8]) throws -> [Parcel] {
        var reader = ByteReader(bytes)
        var parcels: [Parcel] = []
        while reader.remaining > 0 {
            let rawFlavor = try reader.u16()
            let total: Int
            let flavor: UInt16
            if rawFlavor & alternateFlag != 0 {
                flavor = rawFlavor ^ alternateFlag
                _ = try reader.u16()
                total = Int(try reader.u32())
                guard total >= alternateHeaderLength else { throw TeradataWireError.malformed("APH length \(total)") }
                parcels.append(Parcel(flavor: flavor, body: try reader.take(total - alternateHeaderLength)))
            } else {
                flavor = rawFlavor
                total = Int(try reader.u16())
                guard total >= standardHeaderLength else { throw TeradataWireError.malformed("parcel length \(total)") }
                parcels.append(Parcel(flavor: flavor, body: try reader.take(total - standardHeaderLength)))
            }
        }
        return parcels
    }
}
