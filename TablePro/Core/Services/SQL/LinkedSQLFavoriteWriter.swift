//
//  LinkedSQLFavoriteWriter.swift
//  TablePro
//

import Foundation
import os

internal enum LinkedSQLFavoriteWriter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedSQLFavoriteWriter")
    private static let defaultLineBreak = "\n"
    private static let lineBreakCharacters = CharacterSet(charactersIn: "\r\n")

    enum WriteError: Error {
        case readFailed
        case encodingMismatch(String.Encoding)
        case writeFailed
    }

    private struct OutputLine {
        let text: String
        let terminator: String
        let key: SQLFrontmatter.Key?
    }

    static func writeMetadata(
        _ metadata: SQLFrontmatter.Metadata,
        to url: URL
    ) throws {
        guard let loaded = FileTextLoader.load(url) else {
            throw WriteError.readFailed
        }

        let newContent = rewrite(loaded.content, with: metadata)
        do {
            try newContent.write(to: url, atomically: true, encoding: loaded.encoding)
        } catch let error as NSError where
            error.domain == NSCocoaErrorDomain &&
            error.code == NSFileWriteInapplicableStringEncodingError {
            Self.logger.error("Encoding \(loaded.encoding.rawValue) cannot represent edited content at \(url.path, privacy: .private(mask: .hash))")
            throw WriteError.encodingMismatch(loaded.encoding)
        } catch {
            Self.logger.error("Failed to write metadata to \(url.path, privacy: .private(mask: .hash)): \(error.publicLogShape, privacy: .public)")
            throw WriteError.writeFailed
        }
    }

    static func rewrite(_ content: String, with metadata: SQLFrontmatter.Metadata) -> String {
        let document = SQLFrontmatter.split(content)
        let lineBreak = detectedLineBreak(of: document)
        var output: [OutputLine] = []
        var writtenKeys: Set<SQLFrontmatter.Key> = []

        for line in document.header {
            guard let key = line.ownedKey else {
                output.append(OutputLine(text: line.text, terminator: line.terminator, key: nil))
                continue
            }
            guard !writtenKeys.contains(key), let value = headerValue(metadata.value(for: key)) else { continue }
            writtenKeys.insert(key)
            let text = line.value == value ? line.text : renderedLine(key: key, value: value)
            output.append(OutputLine(text: text, terminator: line.terminator, key: key))
        }

        for key in SQLFrontmatter.Key.allCases where !writtenKeys.contains(key) {
            guard let value = headerValue(metadata.value(for: key)) else { continue }
            let index = insertionIndex(for: key, in: output)
            output.insert(
                OutputLine(text: renderedLine(key: key, value: value), terminator: lineBreak, key: key),
                at: index
            )
        }

        let createdHeader = document.header.isEmpty && !output.isEmpty
        let separator = needsSeparator(createdHeader: createdHeader, body: document.body) ? lineBreak : ""
        return document.byteOrderMark + joined(output, lineBreak: lineBreak) + separator + document.body
    }

    private static func headerValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let singleLine = value
            .components(separatedBy: lineBreakCharacters)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return singleLine.isEmpty ? nil : singleLine
    }

    private static func renderedLine(key: SQLFrontmatter.Key, value: String) -> String {
        "-- @\(key.rawValue): \(value)"
    }

    private static func insertionIndex(for key: SQLFrontmatter.Key, in lines: [OutputLine]) -> Int {
        if let preceding = lines.lastIndex(where: { line in line.key.map { $0 < key } ?? false }) {
            return preceding + 1
        }
        return lines.firstIndex { $0.key != nil } ?? 0
    }

    private static func joined(_ lines: [OutputLine], lineBreak: String) -> String {
        lines.enumerated().map { index, line in
            let isLast = index == lines.count - 1
            let terminator = line.terminator.isEmpty && !isLast ? lineBreak : line.terminator
            return line.text + terminator
        }.joined()
    }

    private static func needsSeparator(createdHeader: Bool, body: String) -> Bool {
        guard createdHeader, !body.isEmpty else { return false }
        return !startsWithLineBreak(body)
    }

    private static func startsWithLineBreak(_ text: String) -> Bool {
        (text as NSString).rangeOfCharacter(from: lineBreakCharacters, options: .anchored).location != NSNotFound
    }

    private static func detectedLineBreak(of document: SQLFrontmatter.Document) -> String {
        if let terminator = document.header.lazy.map(\.terminator).first(where: { !$0.isEmpty }) {
            return terminator
        }
        return firstLineBreak(in: document.body) ?? defaultLineBreak
    }

    private static func firstLineBreak(in text: String) -> String? {
        let nsText = text as NSString
        let range = nsText.rangeOfCharacter(from: lineBreakCharacters)
        guard range.location != NSNotFound else { return nil }
        let breakLength = min(2, nsText.length - range.location)
        let candidate = nsText.substring(with: NSRange(location: range.location, length: breakLength))
        if candidate == "\r\n" { return candidate }
        return nsText.substring(with: range)
    }
}
