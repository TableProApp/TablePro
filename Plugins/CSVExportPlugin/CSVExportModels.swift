//
//  CSVExportModels.swift
//  CSVExportPlugin
//

import Foundation
import TableProPluginKit

public enum CSVDelimiter: String, CaseIterable, Identifiable, Codable, Sendable {
    case comma = ","
    case semicolon = ";"
    case tab = "\\t"
    case pipe = "|"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .comma: return ","
        case .semicolon: return ";"
        case .tab: return "\\t"
        case .pipe: return "|"
        }
    }

    public var actualValue: String {
        self == .tab ? "\t" : rawValue
    }
}

public enum CSVQuoteHandling: String, CaseIterable, Identifiable, Codable, Sendable {
    case always = "Always"
    case asNeeded = "Quote if needed"
    case never = "Never"

    public var id: String { rawValue }

    /// `bundle: .main` is the app bundle. A `.tableplugin` ships no string catalog, so a lookup
    /// against its own bundle returns the key verbatim and never falls back.
    public var displayName: String {
        switch self {
        case .always: return String(localized: "Always", bundle: .main)
        case .asNeeded: return String(localized: "Quote if needed", bundle: .main)
        case .never: return String(localized: "Never", bundle: .main)
        }
    }
}

public enum CSVLineBreak: String, CaseIterable, Identifiable, Codable, Sendable {
    case lf = "\\n"
    case crlf = "\\r\\n"
    case cr = "\\r"

    public var id: String { rawValue }

    public var value: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        }
    }
}

public enum CSVDecimalFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case period = "."
    case comma = ","

    public var id: String { rawValue }

    public var separator: String { rawValue }
}

public struct CSVExportOptions: Equatable, Codable, Sendable {
    public var convertNullToEmpty: Bool = true
    public var convertLineBreakToSpace: Bool = false
    public var includeFieldNames: Bool = true
    public var delimiter: CSVDelimiter = .comma
    public var quoteHandling: CSVQuoteHandling = .asNeeded
    public var lineBreak: CSVLineBreak = .lf
    public var decimalFormat: CSVDecimalFormat = .period
    public var sanitizeFormulas: Bool = true

    /// What the file's bytes are written in. UTF-8 keeps every existing export byte for byte.
    public var encoding: PluginTextEncoding = .utf8

    /// Writes the encoding's byte order mark before the first row. Off, because a mark is what
    /// Excel on Windows needs to read UTF-8 and what a reader splitting the first line on the
    /// delimiter reads as part of the first column name. Ignored by an encoding that has no mark,
    /// so a choice made for UTF-8 survives a detour through Windows-1252.
    public var writesByteOrderMark: Bool = false

    public init() {}

    /// A synthesized `init(from:)` throws `keyNotFound` for a key the saved payload predates and
    /// never falls back to the property's default, so adding one would reset what a user chose.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CSVExportOptions()
        convertNullToEmpty = try container.decodeIfPresent(Bool.self, forKey: .convertNullToEmpty)
            ?? defaults.convertNullToEmpty
        convertLineBreakToSpace = try container.decodeIfPresent(Bool.self, forKey: .convertLineBreakToSpace)
            ?? defaults.convertLineBreakToSpace
        includeFieldNames = try container.decodeIfPresent(Bool.self, forKey: .includeFieldNames)
            ?? defaults.includeFieldNames
        delimiter = try container.decodeIfPresent(CSVDelimiter.self, forKey: .delimiter)
            ?? defaults.delimiter
        quoteHandling = try container.decodeIfPresent(CSVQuoteHandling.self, forKey: .quoteHandling)
            ?? defaults.quoteHandling
        lineBreak = try container.decodeIfPresent(CSVLineBreak.self, forKey: .lineBreak)
            ?? defaults.lineBreak
        decimalFormat = try container.decodeIfPresent(CSVDecimalFormat.self, forKey: .decimalFormat)
            ?? defaults.decimalFormat
        sanitizeFormulas = try container.decodeIfPresent(Bool.self, forKey: .sanitizeFormulas)
            ?? defaults.sanitizeFormulas
        encoding = try container.decodeIfPresent(PluginTextEncoding.self, forKey: .encoding)
            ?? defaults.encoding
        writesByteOrderMark = try container.decodeIfPresent(Bool.self, forKey: .writesByteOrderMark)
            ?? defaults.writesByteOrderMark
    }
}
