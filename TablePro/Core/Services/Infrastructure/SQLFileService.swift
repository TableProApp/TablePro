//
//  SQLFileService.swift
//  TablePro
//
//  Service for reading and writing SQL files.
//

import AppKit
import os
import UniformTypeIdentifiers

/// Service for reading and writing SQL files.
enum SQLFileService {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFileService")

    static let supportedExtensions: Set<String> = ["sql", "psql", "pgsql"]

    private static var allowedContentTypes: [UTType] {
        let types = Set(supportedExtensions.compactMap { UTType(filenameExtension: $0) })
        return types.isEmpty ? [.plainText] : Array(types)
    }

    static func writeFile(content: String, to url: URL, encoding: FileTextEncoding) async throws {
        try await Task.detached {
            try FileTextWriter.write(content, to: url, as: encoding)
        }.value
    }

    static func encodingOnDisk(of url: URL) async -> FileTextEncoding? {
        await Task.detached {
            FileTextLoader.load(url)?.textEncoding
        }.value
    }

    static func writeData(_ data: Data, to url: URL) async throws {
        try await Task.detached {
            try FileTextWriter.replaceContents(of: url, with: data, attribute: TextEncodingAttribute.read(from: url))
        }.value
    }

    /// Shows a save panel for .sql files.
    @MainActor
    static func showSavePanel(suggestedName: String = "query.sql") async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = allowedContentTypes
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.message = String(localized: "Save SQL file")
        let response = await panel.begin()
        guard response == .OK else { return nil }
        return panel.url
    }
}
