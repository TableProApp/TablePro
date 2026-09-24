//
//  DataFileKind.swift
//  TablePro
//

import Foundation
import TableProTabularIO
import UniformTypeIdentifiers

enum DataFileFormat: String, Sendable, Equatable, CaseIterable {
    case delimited
    case json
    case jsonLines
    case workbook
}

struct DataFileKind: Sendable, Equatable {
    static let compressedExtension = "gz"

    static let delimitedExtensions: Set<String> = ["csv", "tsv", "tab", "psv", "txt", "dat"]
    static let jsonExtensions: Set<String> = ["json"]
    static let jsonLinesExtensions: Set<String> = ["jsonl", "ndjson"]
    static let workbookExtensions: Set<String> = ["xlsx"]

    static let commaSeparatedType = "public.comma-separated-values-text"
    static let tabSeparatedType = "public.tab-separated-values-text"
    static let pipeSeparatedType = "com.tablepro.pipe-separated-values"
    static let plainTextType = "public.plain-text"
    static let dataType = "com.tablepro.delimited-data"
    static let jsonType = "public.json"
    static let jsonLinesType = "com.tablepro.json-lines"
    static let workbookType = "org.openxmlformats.spreadsheetml.sheet"
    static let gzipType = "org.gnu.gnu-zip-archive"

    static let editableTypes = [commaSeparatedType, tabSeparatedType, pipeSeparatedType, jsonType, jsonLinesType]
    static let readableTypes = editableTypes + [plainTextType, dataType, workbookType, gzipType]

    let format: DataFileFormat
    let contentExtension: String
    let isCompressed: Bool

    var isEditable: Bool {
        !isCompressed && format != .workbook
    }

    var typeIdentifier: String {
        guard !isCompressed else { return Self.gzipType }
        return Self.typeIdentifier(forContentExtension: contentExtension, format: format)
    }

    var saveTypeIdentifier: String {
        Self.typeIdentifier(forContentExtension: isEditable ? contentExtension : "csv", format: isEditable ? format : .delimited)
    }

    static func classify(_ url: URL) -> DataFileKind? {
        let outer = url.pathExtension.lowercased()
        guard outer == compressedExtension else {
            return kind(forContentExtension: outer, compressed: false)
        }
        let inner = url.deletingPathExtension().pathExtension.lowercased()
        return kind(forContentExtension: inner, compressed: true)
    }

    static func kind(forContentExtension fileExtension: String, compressed: Bool) -> DataFileKind? {
        let format: DataFileFormat
        if delimitedExtensions.contains(fileExtension) {
            format = .delimited
        } else if jsonExtensions.contains(fileExtension) {
            format = .json
        } else if jsonLinesExtensions.contains(fileExtension) {
            format = .jsonLines
        } else if workbookExtensions.contains(fileExtension), !compressed {
            format = .workbook
        } else {
            return nil
        }
        return DataFileKind(format: format, contentExtension: fileExtension, isCompressed: compressed)
    }

    static func kind(forTypeIdentifier identifier: String, url: URL?) -> DataFileKind? {
        if let url, let classified = classify(url) {
            return classified
        }
        switch identifier {
        case commaSeparatedType: return DataFileKind(format: .delimited, contentExtension: "csv", isCompressed: false)
        case tabSeparatedType: return DataFileKind(format: .delimited, contentExtension: "tsv", isCompressed: false)
        case pipeSeparatedType: return DataFileKind(format: .delimited, contentExtension: "psv", isCompressed: false)
        case jsonType: return DataFileKind(format: .json, contentExtension: "json", isCompressed: false)
        case jsonLinesType: return DataFileKind(format: .jsonLines, contentExtension: "jsonl", isCompressed: false)
        case workbookType: return DataFileKind(format: .workbook, contentExtension: "xlsx", isCompressed: false)
        default: return nil
        }
    }

    static func typeIdentifier(forContentExtension fileExtension: String, format: DataFileFormat) -> String {
        switch format {
        case .json:
            return jsonType
        case .jsonLines:
            return jsonLinesType
        case .workbook:
            return workbookType
        case .delimited:
            switch fileExtension {
            case "tsv", "tab": return tabSeparatedType
            case "psv": return pipeSeparatedType
            case "txt": return plainTextType
            case "dat": return dataType
            default: return commaSeparatedType
            }
        }
    }

    static func format(forSaveType typeName: String) -> DataFileFormat? {
        switch typeName {
        case commaSeparatedType, tabSeparatedType, pipeSeparatedType, plainTextType, dataType:
            return .delimited
        case jsonType:
            return .json
        case jsonLinesType:
            return .jsonLines
        default:
            return nil
        }
    }

    static func delimiter(forSaveType typeName: String) -> UInt8? {
        switch typeName {
        case commaSeparatedType: return DelimitedDialect.comma
        case tabSeparatedType: return DelimitedDialect.tab
        case pipeSeparatedType: return DelimitedDialect.pipe
        default: return nil
        }
    }

    static func fileExtension(forType typeName: String) -> String? {
        switch typeName {
        case commaSeparatedType: return "csv"
        case tabSeparatedType: return "tsv"
        case pipeSeparatedType: return "psv"
        case plainTextType: return "txt"
        case dataType: return "dat"
        case jsonType: return "json"
        case jsonLinesType: return "jsonl"
        case workbookType: return "xlsx"
        default: return UTType(typeName)?.preferredFilenameExtension
        }
    }
}
