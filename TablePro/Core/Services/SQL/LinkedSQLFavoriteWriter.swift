//
//  LinkedSQLFavoriteWriter.swift
//  TablePro
//

import Foundation
import os

internal enum LinkedSQLFavoriteWriter {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LinkedSQLFavoriteWriter")

    enum WriteError: Error {
        case readFailed
        case encodingMismatch(String.Encoding)
        case writeFailed
    }

    static func writeMetadata(
        _ metadata: SQLFrontmatter.Metadata,
        to url: URL
    ) throws {
        guard let loaded = FileTextLoader.load(url) else {
            throw WriteError.readFailed
        }
        let parsed = SQLFrontmatter.parseWithBody(loaded.content)
        let body = (loaded.content as NSString)
            .substring(from: parsed.bodyCharOffset)

        let newContent = render(metadata: metadata, body: body)
        do {
            try newContent.write(to: url, atomically: true, encoding: loaded.encoding)
        } catch let error as NSError where
            error.domain == NSCocoaErrorDomain &&
            error.code == NSFileWriteInapplicableStringEncodingError {
            Self.logger.error("Encoding \(loaded.encoding.rawValue) cannot represent edited content at \(url.path, privacy: .public)")
            throw WriteError.encodingMismatch(loaded.encoding)
        } catch {
            Self.logger.error("Failed to write metadata to \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw WriteError.writeFailed
        }
    }

    private static func render(metadata: SQLFrontmatter.Metadata, body: String) -> String {
        var lines: [String] = []
        if let name = metadata.name, !name.isEmpty {
            lines.append("-- @name: \(name)")
        }
        if let keyword = metadata.keyword, !keyword.isEmpty {
            lines.append("-- @keyword: \(keyword)")
        }
        if let description = metadata.description, !description.isEmpty {
            lines.append("-- @description: \(description)")
        }

        guard !lines.isEmpty else { return body }

        let frontmatter = lines.joined(separator: "\n") + "\n"
        if body.isEmpty {
            return frontmatter
        }
        if body.hasPrefix("\n") || body.hasPrefix("\r\n") {
            return frontmatter + body
        }
        return frontmatter + "\n" + body
    }
}
