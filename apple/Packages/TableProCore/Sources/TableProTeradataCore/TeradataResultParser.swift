import Foundation
import TableProWireIO

enum TeradataResultParser {
    // The answer is its first result set; a later statement's rows join only when they decode the same way.
    struct Reader {
        private var resultColumns: [ColumnMeta]?
        private var statementColumns: [ColumnMeta] = []
        private var statementJoins = false
        private var firstActivityCount: Int?

        var activityCount: Int { firstActivityCount ?? 0 }

        // False when the consumer wants no more rows.
        mutating func read(
            _ parcels: [Parcel],
            onColumns: ([TeradataColumn]) throws -> Void,
            onRows: ([[TeradataValue]]) throws -> Bool
        ) throws -> Bool {
            if let failure = parcels.first(where: TeradataResultParser.isError) {
                let (code, message) = TeradataResultParser.errorDetail(failure)
                throw TeradataWireError.server(code: code, message: message)
            }
            var rows: [[TeradataValue]] = []
            for parcel in parcels {
                switch parcel.knownFlavor {
                case .success?:
                    if firstActivityCount == nil {
                        firstActivityCount = TeradataResultParser.readActivityCount(fromSuccess: parcel.body)
                    }
                case .prepInfo?, .prepInfoX?:
                    let columns = try TeradataResultParser.parsePrepInfo(
                        parcel.body, extended: parcel.flavor == ParcelFlavor.prepInfoX.rawValue)
                    if let resultColumns {
                        statementJoins = !resultColumns.isEmpty
                            && TeradataResultParser.decodeAlike(columns, resultColumns)
                    } else {
                        resultColumns = columns
                        statementJoins = !columns.isEmpty
                        try onColumns(columns.map {
                            TeradataColumn(name: $0.name, typeCode: $0.typeCode, dataLength: $0.dataLength)
                        })
                    }
                    statementColumns = columns
                case .record? where statementJoins:
                    rows.append(try RecordDecoder.decode(recordBody: parcel.body, columns: statementColumns))
                default:
                    break
                }
            }
            guard !rows.isEmpty else { return true }
            return try onRows(rows)
        }

        // A request that described no result set still answers its consumer, with no columns.
        mutating func finish(onColumns: ([TeradataColumn]) throws -> Void) throws {
            guard resultColumns == nil else { return }
            resultColumns = []
            try onColumns([])
        }
    }

    static func errorDetail(_ parcel: Parcel) -> (code: Int, message: String) {
        let body = parcel.body
        guard body.count >= 12 else { return (0, decodedText(body)) }
        let code = Int(body[8]) << 8 | Int(body[9])
        let messageLength = Int(body[10]) << 8 | Int(body[11])
        let end = min(12 + messageLength, body.count)
        let message = decodedText(body[12..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, message.isEmpty ? decodedText(body) : message)
    }

    private static func isError(_ parcel: Parcel) -> Bool {
        parcel.flavor == ParcelFlavor.failure.rawValue
            || parcel.flavor == ParcelFlavor.error.rawValue
            || parcel.flavor == ParcelFlavor.statementError.rawValue
    }

    // A record decodes by each field's base type and declared length, so two descriptions alike in those read it alike.
    private static func decodeAlike(_ lhs: [ColumnMeta], _ rhs: [ColumnMeta]) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy { $0.baseCode == $1.baseCode && $0.dataLength == $1.dataLength }
    }

    private static func decodedText(_ bytes: some Collection<UInt8>) -> String {
        String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func readActivityCount(fromSuccess body: [UInt8]) -> Int {
        guard body.count >= 6 else { return 0 }
        return Int(body[2]) << 24 | Int(body[3]) << 16 | Int(body[4]) << 8 | Int(body[5])
    }

    private static func parsePrepInfo(_ body: [UInt8], extended: Bool) throws -> [ColumnMeta] {
        var reader = ByteReader(body)
        _ = try reader.take(8)
        let summaryCount = Int(try reader.u16())
        let columnCount = Int(try reader.u16())
        var items: [ColumnMeta] = []
        for _ in 0..<(summaryCount + columnCount) {
            let dataType = try reader.u16()
            let dataLength: Int
            if extended {
                let raw = try reader.take(8)
                dataLength = Int(TeradataType.signedInteger(raw))
                _ = try reader.u8()
                _ = try reader.u8()
            } else {
                dataLength = Int(try reader.u16())
            }
            let name = try readShortString(&reader)
            _ = try readShortString(&reader)
            let title = try readShortString(&reader)
            items.append(ColumnMeta(
                typeCode: dataType, dataLength: dataLength, name: name.isEmpty ? title : name))
        }
        guard items.count >= columnCount else { return items }
        return Array(items.suffix(columnCount))
    }

    private static func readShortString(_ reader: inout ByteReader) throws -> String {
        let length = Int(try reader.u16())
        guard length > 0 else { return "" }
        return decodedText(try reader.take(length))
    }
}
