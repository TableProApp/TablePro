import Foundation

/// RFC 4180 records. A blank line comes back as an empty record because the Flux annotated CSV
/// uses it to separate one table from the next.
enum InfluxCSV {
    static func records(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        var iterator = Array(text.unicodeScalars).makeIterator()
        var pending: Unicode.Scalar?

        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return iterator.next()
        }

        func endRecord() {
            if fieldStarted || !record.isEmpty {
                record.append(field)
                records.append(record)
            } else {
                records.append([])
            }
            record = []
            field = ""
            fieldStarted = false
        }

        while let scalar = next() {
            if inQuotes {
                if scalar == "\"" {
                    if let following = next() {
                        if following == "\"" {
                            field.unicodeScalars.append("\"")
                        } else {
                            inQuotes = false
                            pending = following
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
                continue
            }
            switch scalar {
            case "\"":
                inQuotes = true
                fieldStarted = true
            case ",":
                record.append(field)
                field = ""
                fieldStarted = true
            case "\r":
                if let following = next(), following != "\n" {
                    pending = following
                }
                endRecord()
            case "\n":
                endRecord()
            default:
                field.unicodeScalars.append(scalar)
                fieldStarted = true
            }
        }
        if fieldStarted || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }
}
