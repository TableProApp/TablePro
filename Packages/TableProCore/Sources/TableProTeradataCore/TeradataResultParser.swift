import Foundation

enum TeradataResultParser {
    static func parse(_ parcels: [Parcel]) throws -> TeradataResultSet {
        for parcel in parcels where parcel.flavor == ParcelFlavor.failure.rawValue
            || parcel.flavor == ParcelFlavor.error.rawValue
            || parcel.flavor == ParcelFlavor.statementError.rawValue {
            let (code, message) = errorDetail(parcel)
            throw TeradataWireError.server(code: code, message: message)
        }

        let activityCount = parcels
            .first { $0.flavor == ParcelFlavor.success.rawValue }
            .map { readActivityCount(fromSuccess: $0.body) } ?? 0

        var columns: [ColumnMeta] = []
        if let prepInfoX = parcels.first(where: { $0.flavor == ParcelFlavor.prepInfoX.rawValue }) {
            columns = try parsePrepInfo(prepInfoX.body, extended: true)
        } else if let prepInfo = parcels.first(where: { $0.flavor == ParcelFlavor.prepInfo.rawValue }) {
            columns = try parsePrepInfo(prepInfo.body, extended: false)
        }

        var rows: [[TeradataValue]] = []
        if !columns.isEmpty {
            for record in parcels where record.flavor == ParcelFlavor.record.rawValue {
                rows.append(try RecordDecoder.decode(recordBody: record.body, columns: columns))
            }
        }

        let resultColumns = columns.map {
            TeradataColumn(name: $0.name, typeCode: $0.typeCode, dataLength: $0.dataLength)
        }
        return TeradataResultSet(columns: resultColumns, rows: rows, activityCount: activityCount)
    }

    static func errorDetail(_ parcel: Parcel) -> (code: Int, message: String) {
        let body = parcel.body
        guard body.count >= 12 else { return (0, String(decoding: body, as: UTF8.self)) }
        let code = Int(body[8]) << 8 | Int(body[9])
        let messageLength = Int(body[10]) << 8 | Int(body[11])
        let end = min(12 + messageLength, body.count)
        let message = String(decoding: body[12..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, message.isEmpty ? String(decoding: body, as: UTF8.self) : message)
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
        return String(decoding: try reader.take(length), as: UTF8.self)
    }
}
