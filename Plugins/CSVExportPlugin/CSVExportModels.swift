//
//  CSVExportModels.swift
//  CSVExportPlugin
//

import Foundation

public enum CSVDelimiter: String, CaseIterable, Identifiable, Codable {
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

public enum CSVQuoteHandling: String, CaseIterable, Identifiable, Codable {
    case always = "Always"
    case asNeeded = "Quote if needed"
    case never = "Never"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .always: return String(localized: "Always", bundle: Bundle(for: CSVExportPlugin.self))
        case .asNeeded: return String(localized: "Quote if needed", bundle: Bundle(for: CSVExportPlugin.self))
        case .never: return String(localized: "Never", bundle: Bundle(for: CSVExportPlugin.self))
        }
    }
}

public enum CSVLineBreak: String, CaseIterable, Identifiable, Codable {
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

public enum CSVDecimalFormat: String, CaseIterable, Identifiable, Codable {
    case period = "."
    case comma = ","

    public var id: String { rawValue }

    public var separator: String { rawValue }
}

public struct CSVExportOptions: Equatable, Codable {
    public var convertNullToEmpty: Bool = true
    public var convertLineBreakToSpace: Bool = false
    public var includeFieldNames: Bool = true
    public var delimiter: CSVDelimiter = .comma
    public var quoteHandling: CSVQuoteHandling = .asNeeded
    public var lineBreak: CSVLineBreak = .lf
    public var decimalFormat: CSVDecimalFormat = .period
    public var sanitizeFormulas: Bool = true

    public init() {}
}
