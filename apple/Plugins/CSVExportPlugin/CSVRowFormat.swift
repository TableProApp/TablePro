//
//  CSVRowFormat.swift
//  CSVExportPlugin
//

import Foundation
import TableProPluginKit

nonisolated struct CSVRowFormat {
    let options: CSVExportOptions
    let delimiter: String
    let lineBreak: String

    private let plainWriteOptions: PluginCsvWriteOptions
    private let sanitizingWriteOptions: PluginCsvWriteOptions
    private let attentionBytes: [Bool]
    private let attentionBytesWithDecimalComma: [Bool]

    init(options: CSVExportOptions) {
        self.options = options
        delimiter = options.delimiter.actualValue
        lineBreak = options.lineBreak.value
        plainWriteOptions = Self.writeOptions(options, sanitizes: false)
        sanitizingWriteOptions = Self.writeOptions(options, sanitizes: true)

        var attention = [Bool](repeating: false, count: 256)
        for byte in Self.bytesNeedingAttention(options) {
            attention[Int(byte)] = true
        }
        attentionBytes = attention
        attention[Int(UInt8(ascii: "."))] = options.decimalFormat == .comma
        attentionBytesWithDecimalComma = attention
    }

    func writeOptions(sanitizes: Bool) -> PluginCsvWriteOptions {
        sanitizes ? sanitizingWriteOptions : plainWriteOptions
    }

    // True only when no rule can change the value, so every other value still takes the one escaping path.
    func writesVerbatim(_ value: String, takesDecimalComma: Bool) -> Bool {
        let attention = takesDecimalComma ? attentionBytesWithDecimalComma : attentionBytes
        let isVerbatim = value.utf8.withContiguousStorageIfAvailable { bytes -> Bool in
            if options.sanitizeFormulas, let first = bytes.first, Self.mayLeadFormula(first) {
                return false
            }
            return !bytes.contains { attention[Int($0)] }
        }
        return isVerbatim ?? false
    }

    // 0xEF opens every full-width formula operator. `PluginRowWriters` decides what such a value really is.
    private static func mayLeadFormula(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "="), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "@"),
             UInt8(ascii: "\t"), UInt8(ascii: "\r"), UInt8(ascii: "\n"), 0xEF:
            return true
        default:
            return false
        }
    }

    private static func bytesNeedingAttention(_ options: CSVExportOptions) -> [UInt8] {
        let lineBreaks = [UInt8(ascii: "\n"), UInt8(ascii: "\r")]
        switch options.quoteHandling {
        case .always:
            return lineBreaks + [UInt8(ascii: "\"")]
        case .never:
            return lineBreaks
        case .asNeeded:
            return lineBreaks + [UInt8(ascii: "\""), UInt8(ascii: "\t")] + Array(options.delimiter.actualValue.utf8)
        }
    }

    private static func writeOptions(_ options: CSVExportOptions, sanitizes: Bool) -> PluginCsvWriteOptions {
        PluginCsvWriteOptions(
            delimiter: options.delimiter.actualValue,
            quoteHandling: quoteHandling(options.quoteHandling),
            lineEnding: options.lineBreak.value,
            nullAsEmpty: true,
            sanitizesFormulas: sanitizes,
            flattensLineBreaks: false
        )
    }

    private static func quoteHandling(_ handling: CSVQuoteHandling) -> PluginCsvWriteOptions.QuoteHandling {
        switch handling {
        case .always: return .always
        case .never: return .never
        case .asNeeded: return .asNeeded
        }
    }
}
