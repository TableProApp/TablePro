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
    var table: TabularTable?
    var kinds: [TabularColumnID: TabularInferredKind]
    let workbookSheet: XLSXSheet?
}

struct DataFileContent: Sendable {
    let kind: DataFileKind
    let sheets: [DataFileSheet]
    let initialSheetIndex: Int
    let delimitedSource: DelimitedSource?
    let jsonSource: JSONSource?
    let workbook: XLSXWorkbook?
    let dialect: DelimitedDialect?
    let raggedRowCount: Int
    let undecodableLineCount: Int
}

struct DataFileLoadedSheet: Sendable {
    let table: TabularTable
    let kinds: [TabularColumnID: TabularInferredKind]
}

extension Error {
    var isDataFileCancellation: Bool {
        self is CancellationError || self is TabularCancellation
    }
}

enum DataFileLoadError: LocalizedError, Equatable {
    case unreadable(String)
    case unsupported(String)
    case invalidJSON(JSONTableError)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return String(format: String(localized: "The file could not be read: %@"), message)
        case .unsupported(let message):
            return message
        case .invalidJSON(let error):
            return Self.message(for: error)
        }
    }

    private static func message(for error: JSONTableError) -> String {
        switch error {
        case .emptyDocument:
            return String(localized: "The file is empty.")
        case .unsupportedEncoding:
            return String(localized: "Only UTF-8 JSON files can be opened.")
        case .singleObject:
            return String(localized: "The file holds one object, not a list of rows. Open a JSON array of objects or a JSON Lines file.")
        case .scalarDocument:
            return String(localized: "The file holds a single value, not a list of rows.")
        case .rowIsNotAnObject(let row, _):
            return String(format: String(localized: "Row %@ is not an object."), (row + 1).formatted())
        case .truncated(let row, let offset), .unexpectedByte(let row, let offset),
             .mismatchedBracket(let row, let offset), .trailingContent(let row, let offset),
             .invalidString(let row, let offset), .invalidEscape(let row, let offset),
             .invalidNumber(let row, let offset), .invalidLiteral(let row, let offset):
            return String(
                format: String(localized: "Row %@ is not valid JSON near byte %@."),
                (row + 1).formatted(),
                offset.formatted()
            )
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
        case .workbook:
            return try loadWorkbook(request, snapshotURL: snapshotURL, progress: progress)
        case .json, .jsonLines:
            return try await loadJSON(request, snapshotURL: snapshotURL, progress: progress)
        }
    }

    private static func loadJSON(
        _ request: DataFileLoadRequest,
        snapshotURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DataFileContent {
        let bytes = try mappedData(at: snapshotURL)
        let source: JSONSource
        do {
            source = try await JSONSourceBuilder.build(
                bytes: bytes,
                fileKind: JSONTableFileKind.forFileExtension(request.kind.contentExtension),
                progress: { progress($0 * 0.95) },
                isCancelled: { Task.isCancelled }
            )
        } catch let error as JSONTableError {
            throw DataFileLoadError.invalidJSON(error)
        }
        let table = TabularTable(source: source, usesFirstRowAsHeader: false)
        let kinds = TabularTypeInference.inferKinds(of: table)
        progress(1)
        let sheet = DataFileSheet(
            name: request.url.lastPathComponent,
            isHidden: false,
            table: table,
            kinds: kinds,
            workbookSheet: nil
        )
        return DataFileContent(
            kind: request.kind,
            sheets: [sheet],
            initialSheetIndex: 0,
            delimitedSource: nil,
            jsonSource: source,
            workbook: nil,
            dialect: nil,
            raggedRowCount: 0,
            undecodableLineCount: 0
        )
    }

    @concurrent
    static func loadSheet(
        _ sheet: XLSXSheet,
        of workbook: XLSXWorkbook,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> DataFileLoadedSheet {
        let source = try workbook.source(for: sheet, progress: progress, isCancelled: { Task.isCancelled })
        let table = TabularTable(source: source, usesFirstRowAsHeader: source.firstRowLooksLikeHeader)
        return DataFileLoadedSheet(table: table, kinds: TabularTypeInference.inferKinds(of: table))
    }

    private static func loadWorkbook(
        _ request: DataFileLoadRequest,
        snapshotURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) throws -> DataFileContent {
        let workbook = try XLSXWorkbook(
            contentsOf: snapshotURL,
            progress: { progress($0 * 0.1) },
            isCancelled: { Task.isCancelled }
        )
        guard let initial = workbook.sheets.firstIndex(where: { !$0.isHidden }) ?? workbook.sheets.indices.first else {
            throw DataFileLoadError.unsupported(String(localized: "This workbook has no worksheets."))
        }
        let first = workbook.sheets[initial]
        let source = try workbook.source(for: first, progress: { progress(0.1 + $0 * 0.9) }, isCancelled: { Task.isCancelled })
        let table = TabularTable(source: source, usesFirstRowAsHeader: source.firstRowLooksLikeHeader)
        let kinds = TabularTypeInference.inferKinds(of: table)
        let sheets = workbook.sheets.map { sheet in
            DataFileSheet(
                name: sheet.name,
                isHidden: sheet.isHidden,
                table: sheet == first ? table : nil,
                kinds: sheet == first ? kinds : [:],
                workbookSheet: sheet
            )
        }
        progress(1)
        return DataFileContent(
            kind: request.kind,
            sheets: sheets,
            initialSheetIndex: initial,
            delimitedSource: nil,
            jsonSource: nil,
            workbook: workbook,
            dialect: nil,
            raggedRowCount: 0,
            undecodableLineCount: 0
        )
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
        let contents: DelimitedFileContents
        do {
            contents = try await DelimitedFileReader.read(
                original,
                fileExtension: request.kind.contentExtension,
                dialectOverride: request.dialectOverride,
                transcodedFileURL: workingCopy.file(named: "utf8-\(UUID().uuidString).txt"),
                progress: progress,
                isCancelled: { Task.isCancelled }
            )
        } catch TabularWriteError.couldNotCreate(let path) {
            throw DataFileLoadError.unreadable(String(format: String(localized: "Could not create %@."), path))
        } catch TabularWriteError.writeFailed(let message) {
            throw DataFileLoadError.unreadable(message)
        } catch let error as CocoaError {
            throw DataFileLoadError.unreadable(error.localizedDescription)
        }
        let source = contents.source
        let table = TabularTable(source: source, usesFirstRowAsHeader: source.dialect.hasHeaderRow)
        let kinds = TabularTypeInference.inferKinds(of: table)
        progress(1)
        let sheet = DataFileSheet(
            name: request.url.lastPathComponent,
            isHidden: false,
            table: table,
            kinds: kinds,
            workbookSheet: nil
        )
        return DataFileContent(
            kind: request.kind,
            sheets: [sheet],
            initialSheetIndex: 0,
            delimitedSource: source,
            jsonSource: nil,
            workbook: nil,
            dialect: source.dialect,
            raggedRowCount: source.raggedRowCount,
            undecodableLineCount: contents.undecodableLineCount
        )
    }
}
