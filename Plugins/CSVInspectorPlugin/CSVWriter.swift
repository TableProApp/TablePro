import Foundation
import TableProPluginKit

struct CSVWriter {
    enum WriteError: Error, LocalizedError {
        case encodingFailed
        case writeFailed(underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .encodingFailed:
                return String(localized: "Could not encode CSV content")
            case .writeFailed(let underlying):
                if let underlying {
                    return String(format: String(localized: "Failed to write CSV file: %@"), underlying.localizedDescription)
                }
                return String(localized: "Failed to write CSV file")
            }
        }
    }

    private static let flushThreshold = 1 << 20

    let dialect: CSVDialect

    func write(_ store: CSVRowStore, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).tmp.\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WriteError.writeFailed(underlying: nil)
        }

        do {
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(Self.flushThreshold + 4_096)
            buffer.append(contentsOf: dialect.bomBytes)

            append(store.headerSource, from: store, into: &buffer)
            if buffer.count >= Self.flushThreshold {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }

            for row in 0..<store.rowCount {
                append(store.rowSource(at: row), from: store, into: &buffer)
                if buffer.count >= Self.flushThreshold {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.writeFailed(underlying: error)
        }

        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw WriteError.writeFailed(underlying: error)
        }
    }

    func encodeRow(_ cells: [String]) -> String {
        let delimiterScalar = UnicodeScalar(dialect.delimiter)
        let quoteScalar = UnicodeScalar(dialect.quoteChar)
        let delimiter = String(delimiterScalar)
        let quote = String(quoteScalar)
        let doubledQuote = quote + quote

        var line = ""
        for (index, field) in cells.enumerated() {
            if index > 0 {
                line += delimiter
            }
            line += Self.encodeField(
                field,
                delimiterScalar: delimiterScalar,
                quoteScalar: quoteScalar,
                quote: quote,
                doubledQuote: doubledQuote
            )
        }
        return line
    }

    private func append(_ source: CSVRowStore.RowSource, from store: CSVRowStore, into buffer: inout Data) {
        switch source {
        case .rawBytes(let range):
            buffer.append(store.data[range])
        case .cells(let cells):
            if let line = encodeRow(cells).data(using: dialect.encoding) {
                buffer.append(line)
            }
            buffer.append(contentsOf: dialect.lineEnding.bytes)
        }
    }

    private static func encodeField(
        _ field: String,
        delimiterScalar: UnicodeScalar,
        quoteScalar: UnicodeScalar,
        quote: String,
        doubledQuote: String
    ) -> String {
        let needsQuoting = field.unicodeScalars.contains { scalar in
            scalar == delimiterScalar || scalar == quoteScalar || scalar == "\n" || scalar == "\r"
        }
        guard needsQuoting else { return field }
        return quote + field.replacingOccurrences(of: quote, with: doubledQuote) + quote
    }
}
