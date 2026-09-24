//
//  DataFileLoader.swift
//  TablePro
//

import Foundation
import TableProTabular
import TableProTabularIO

struct DataFileLoadRequest: Sendable {
    let url: URL
    let kind: DataFileKind
    let dialectOverride: DelimitedDialect?
}

struct DataFileSheet: Sendable {
    let name: String
    let isHidden: Bool
    let table: TabularTable
    let kinds: [TabularColumnID: TabularInferredKind]
}

struct DataFileContent: Sendable {
    let kind: DataFileKind
    let sheets: [DataFileSheet]
    let delimitedSource: DelimitedSource?
    let dialect: DelimitedDialect?
    let raggedRowCount: Int
}

enum DataFileLoadError: LocalizedError, Equatable {
    case unreadable(String)
    case undecodable(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return String(format: String(localized: "The file could not be read: %@"), message)
        case .undecodable(let encoding):
            return String(format: String(localized: "The file is not valid %@ text."), encoding)
        case .unsupported(let message):
            return message
        }
    }
}

enum DataFileLoader {
    @concurrent
    static func load(
        _ request: DataFileLoadRequest,
        workingCopy: DataFileWorkingCopy,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DataFileContent {
        let snapshotURL: URL
        do {
            snapshotURL = try await workingCopy.snapshot(of: request.url, kind: request.kind)
        } catch {
            throw DataFileLoadError.unreadable(error.localizedDescription)
        }
        try Task.checkCancellation()
        switch request.kind.format {
        case .delimited:
            return try await loadDelimited(request, snapshotURL: snapshotURL, workingCopy: workingCopy, progress: progress)
        case .json, .jsonLines, .workbook:
            throw DataFileLoadError.unsupported(String(localized: "This kind of file cannot be opened yet."))
        }
    }

    static func mappedData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw DataFileLoadError.unreadable(error.localizedDescription)
        }
    }

    private static func loadDelimited(
        _ request: DataFileLoadRequest,
        snapshotURL: URL,
        workingCopy: DataFileWorkingCopy,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DataFileContent {
        let original = try mappedData(at: snapshotURL)
        let sniff = original.withUnsafeBytes { raw in
            DelimitedDialectDetector.sniffEncoding(raw.bindMemory(to: UInt8.self))
        }
        let fileEncoding = request.dialectOverride?.encoding ?? sniff.encoding
        let prefixLength = fileEncoding == sniff.encoding ? sniff.byteOrderMarkLength : 0
        let bytes: Data
        let byteEncoding: TabularTextEncoding
        let contentStart: Int
        if fileEncoding.readsInPlace {
            bytes = original
            byteEncoding = fileEncoding
            contentStart = prefixLength
        } else {
            do {
                let converted = try TabularTextTranscoder.utf8Data(from: original, encoding: fileEncoding, skippingPrefix: prefixLength)
                let convertedURL = workingCopy.file(named: "utf8-\(UUID().uuidString).txt")
                try converted.write(to: convertedURL)
                bytes = try mappedData(at: convertedURL)
            } catch is TabularTranscodingError {
                throw DataFileLoadError.undecodable(DataFileEncodingNames.name(for: fileEncoding))
            }
            byteEncoding = .utf8
            contentStart = 0
        }
        try Task.checkCancellation()
        let detected = bytes.withUnsafeBytes { raw in
            DelimitedDialectDetector.detect(
                raw.bindMemory(to: UInt8.self),
                contentStart: contentStart,
                encoding: fileEncoding,
                hasByteOrderMark: sniff.hasByteOrderMark && fileEncoding == sniff.encoding,
                fileExtension: request.kind.contentExtension
            )
        }
        let dialect = request.dialectOverride ?? detected
        let source = try await DelimitedSourceBuilder.build(
            bytes: bytes,
            dialect: dialect,
            byteEncoding: byteEncoding,
            contentStart: contentStart,
            progress: { progress($0 * 0.95) },
            isCancelled: { Task.isCancelled }
        )
        let table = TabularTable(source: source, usesFirstRowAsHeader: dialect.hasHeaderRow)
        let kinds = TabularTypeInference.inferKinds(of: table)
        progress(1)
        let sheet = DataFileSheet(name: request.url.lastPathComponent, isHidden: false, table: table, kinds: kinds)
        return DataFileContent(
            kind: request.kind,
            sheets: [sheet],
            delimitedSource: source,
            dialect: dialect,
            raggedRowCount: source.raggedRowCount
        )
    }
}

enum DataFileEncodingNames {
    static func name(for encoding: TabularTextEncoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf16BigEndian: return "UTF-16 BE"
        case .windows1252: return "Windows-1252"
        case .isoLatin1: return "ISO Latin 1"
        case .shiftJIS: return "Shift JIS"
        case .gb18030: return "GB 18030"
        case .big5: return "Big5"
        case .eucKR: return "EUC-KR"
        }
    }
}
