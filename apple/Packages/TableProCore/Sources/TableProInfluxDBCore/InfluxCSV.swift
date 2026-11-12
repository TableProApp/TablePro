import Foundation

// RFC 4180 over the raw bytes. An empty line is one record with one empty field: the null of a one-column result, and
// the separator between Flux tables. Every delimiter is ASCII, so a field is decoded on its own and bad UTF-8 in one
// value does not empty the whole grid.
enum InfluxCSV {
    static func records(_ data: Data) -> [[String]] {
        var reader = Reader()
        reader.read(data)
        return reader.finish()
    }

    // Holds its state between reads, so a body can be split anywhere: inside a quoted field, between the two quotes of
    // an escaped one, or between the CR and LF of one line end.
    struct Reader {
        private var records: [[String]] = []
        private var record: [String] = []
        private var field: [UInt8] = []
        private var inQuotes = false
        // A quote right after the one that closed a quoted field is an escaped quote inside it.
        private var closedQuote = false
        // An LF right after the CR that ended a record is the same line end.
        private var endedOnCarriageReturn = false
        private var lineHasContent = false

        mutating func read(_ data: Data) {
            data.withUnsafeBytes { read($0) }
        }

        mutating func read(_ bytes: UnsafeRawBufferPointer) {
            for byte in bytes {
                if endedOnCarriageReturn {
                    endedOnCarriageReturn = false
                    if byte == Self.lineFeed { continue }
                }
                if inQuotes {
                    if byte == Self.quote {
                        inQuotes = false
                        closedQuote = true
                    } else {
                        field.append(byte)
                    }
                    continue
                }
                let afterClosingQuote = closedQuote
                closedQuote = false
                switch byte {
                case Self.quote:
                    if afterClosingQuote { field.append(Self.quote) }
                    inQuotes = true
                    lineHasContent = true
                case Self.comma:
                    endField()
                    lineHasContent = true
                case Self.carriageReturn:
                    endRecord()
                    endedOnCarriageReturn = true
                case Self.lineFeed:
                    endRecord()
                default:
                    field.append(byte)
                    lineHasContent = true
                }
            }
        }

        // The records completed so far. One still open stays for the next read.
        mutating func drain() -> [[String]] {
            let completed = records
            records = []
            return completed
        }

        mutating func finish() -> [[String]] {
            if lineHasContent || !record.isEmpty { endRecord() }
            return drain()
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
