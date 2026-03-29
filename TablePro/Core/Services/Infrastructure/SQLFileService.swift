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

    /// Reads a SQL file from disk.
    static func readFile(url: URL) async throws -> String {
        try await Task.detached {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    /// Writes content to a SQL file atomically.
    static func writeFile(content: String, to url: URL) async throws {
        try await Task.detached {
            guard let data = content.data(using: .utf8) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            try data.write(to: url, options: .atomic)
        }.value
    }

    /// Shows an open panel for .sql files.
    @MainActor
    static func showOpenPanel() async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Select SQL files to open")
        let response = await panel.begin()
        guard response == .OK else { return nil }
        return panel.urls
    }

    /// Shows a save panel for .sql files.
    @MainActor
    static func showSavePanel(suggestedName: String = "query.sql") async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        panel.message = String(localized: "Save SQL file")
        let response = await panel.begin()
        guard response == .OK else { return nil }
        return panel.url
    }
}
