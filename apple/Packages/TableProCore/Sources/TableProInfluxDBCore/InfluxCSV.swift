import Foundation

// RFC 4180 over the raw bytes. An empty line is one record with one empty field: the null of a one-column result, and
// the separator between Flux tables. Every delimiter is ASCII, so a field is decoded on its own and bad UTF-8 in one
// value does not empty the whole grid.
enum InfluxCSV {
    static func records(_ data: Data) -> [[String]] {
        var reader = Reader()
        data.withUnsafeBytes { reader.read($0) }
        return reader.finish()
    }

    private struct Reader {
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var lineHasContent = false

        mutating func read(_ bytes: UnsafeRawBufferPointer) {
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if inQuotes {
                    if byte == Self.quote, index < bytes.count, bytes[index] == Self.quote {
                        field.append(Self.quote)
                        index += 1
                    } else if byte == Self.quote {
                        inQuotes = false
                    } else {
                        field.append(byte)
                    }
                    continue
                }
                switch byte {
                case Self.quote:
                    inQuotes = true
                    lineHasContent = true
                case Self.comma:
                    endField()
                    lineHasContent = true
                case Self.carriageReturn:
                    if index < bytes.count, bytes[index] == Self.lineFeed { index += 1 }
                    endRecord()
                case Self.lineFeed:
                    endRecord()
                default:
                    field.append(byte)
                    lineHasContent = true
                }
            }
        }

        mutating func finish() -> [[String]] {
            if lineHasContent || !record.isEmpty { endRecord() }
            return records
        }

        private mutating func endField() {
            record.append(String(decoding: field, as: UTF8.self)) // swiftlint:disable:this optional_data_string_conversion
            field.removeAll(keepingCapacity: true)
        }

        private mutating func endRecord() {
            endField()
            records.append(record)
            record = []
            lineHasContent = false
        }

        static let quote = UInt8(ascii: "\"")
        static let comma = UInt8(ascii: ",")
        static let carriageReturn = UInt8(ascii: "\r")
        static let lineFeed = UInt8(ascii: "\n")
    }
}
