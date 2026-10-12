//
//  CSVImportText.swift
//  CSVImportPlugin
//

import Foundation
import TableProTabularIO

struct CSVImportText {
    let data: Data
    let encoding: TabularTextEncoding
    let firstUndecodableLine: Int?
    private let temporaryURL: URL?

    static func prefix(of url: URL, length: Int, encoding option: CSVImportOptions.TextEncoding) throws -> CSVImportText {
        let file = try Data(contentsOf: url, options: .alwaysMapped)
        let head = file.prefix(length)
        let sniff = resolvedEncoding(of: head, isWholeFile: head.count == file.count, option: option)
        let transcoded = try TabularTextTranscoder.utf8Data(
            from: file,
            encoding: sniff.encoding,
            skippingPrefix: sniff.byteOrderMarkLength,
            wholeLinesWithin: length
        )
        return CSVImportText(
            data: transcoded.data,
            encoding: sniff.encoding,
            firstUndecodableLine: transcoded.firstUndecodableLine,
            temporaryURL: nil
        )
    }

    static func contents(
        of url: URL,
        encoding option: CSVImportOptions.TextEncoding,
        copyingInto directory: URL = FileManager.default.temporaryDirectory,
        isCancelled: () -> Bool = { false }
    ) throws -> CSVImportText {
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        let sniff = resolvedEncoding(of: file, isWholeFile: true, option: option)
        guard sniff.encoding != .utf8 else {
            return CSVImportText(
                data: file,
                encoding: .utf8,
                firstUndecodableLine: TabularTextTranscoder.firstInvalidUTF8Line(
                    in: file,
                    skippingPrefix: sniff.byteOrderMarkLength
                ),
                temporaryURL: nil
            )
        }
        let temporaryURL = directory.appendingPathComponent("TablePro-CSVImport-\(UUID().uuidString).csv")
        do {
            let transcoded = try TabularTextTranscoder.transcode(
                file,
                from: sniff.encoding,
                skippingPrefix: sniff.byteOrderMarkLength,
                to: temporaryURL,
                isCancelled: isCancelled
            )
            return CSVImportText(
                data: try Data(contentsOf: temporaryURL, options: .alwaysMapped),
                encoding: sniff.encoding,
                firstUndecodableLine: transcoded.firstUndecodableLine,
                temporaryURL: temporaryURL
            )
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private static func resolvedEncoding(
        of file: Data,
        isWholeFile: Bool,
        option: CSVImportOptions.TextEncoding
    ) -> TabularEncodingSniff {
        let sniff = TabularEncodingDetector.sniff(file, isWholeFile: isWholeFile)
        guard let chosen = option.tabularEncoding, chosen != sniff.encoding else { return sniff }
        return TabularEncodingSniff(encoding: chosen, byteOrderMarkLength: 0)
    }
}
