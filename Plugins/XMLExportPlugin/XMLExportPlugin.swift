//
//  XMLExportPlugin.swift
//  XMLExportPlugin
//

import Foundation
import os
import SwiftUI
import TableProPluginKit

@Observable
final class XMLExportPlugin: ExportFormatPlugin, SettablePlugin, @unchecked Sendable {
    static let pluginName = "XML Export"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "Export data to XML"
    static let formatId = "xml"
    static let formatDisplayName = "XML"
    static let defaultFileExtension = "xml"
    static let iconName = "doc.badge.gearshape"

    typealias Settings = XMLExportOptions
    static let settingsStorageId = "xml"

    var settings = XMLExportOptions() {
        didSet { saveSettings() }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "XMLExportPlugin")

    required init() { loadSettings() }

    @MainActor
    func settingsView() -> AnyView? {
        AnyView(XMLExportOptionsView(plugin: self))
    }

    func resetSettingsToDefaults() {
        settings = XMLExportOptions()
    }

    func export(
        tables: [PluginExportTable],
        dataSource: any PluginExportDataSource,
        destination: URL,
        progress: PluginExportProgress
    ) async throws -> ExportFormatResult {
        let (fileHandle, tempURL) = try PluginExportUtilities.beginAtomicWrite(for: destination)
        var committed = false
        defer {
            if !committed { PluginExportUtilities.rollbackAtomicWrite(at: tempURL) }
        }

        let newline = settings.prettyPrint ? "\n" : ""
        let indent = settings.prettyPrint ? "  " : ""

        try fileHandle.write(contentsOf: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\(newline)".toUTF8Data())
        /// The namespace is declared once on the root, because `xsi:nil` on a row element is only
        /// legal when something above it declares the prefix.
        let rootAttributes = settings.marksNulls
            ? " xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\""
            : ""
        try fileHandle.write(contentsOf: "<export\(rootAttributes)>\(newline)".toUTF8Data())

        for (index, table) in tables.enumerated() {
            try progress.checkCancellation()
            progress.setCurrentTable(table.qualifiedName, index: index + 1)
            let tableElement = XMLEscaping.elementName(table.name)
            try fileHandle.write(contentsOf: (
                "\(indent)<table name=\"\(XMLEscaping.text(table.qualifiedName))\">\(newline)"
            ).toUTF8Data())
            try await writeRows(
                table, element: tableElement, dataSource: dataSource,
                to: fileHandle, progress: progress, indent: indent, newline: newline)
            try fileHandle.write(contentsOf: "\(indent)</table>\(newline)".toUTF8Data())
        }

        try fileHandle.write(contentsOf: "</export>\(newline)".toUTF8Data())
        try fileHandle.close()
        try PluginExportUtilities.commitAtomicWrite(from: tempURL, to: destination)
        committed = true
        progress.finalizeTable()
        return ExportFormatResult()
    }

    private func writeRows(
        _ table: PluginExportTable,
        element: String,
        dataSource: any PluginExportDataSource,
        to fileHandle: FileHandle,
        progress: PluginExportProgress,
        indent: String,
        newline: String
    ) async throws {
        var columns: [String] = []
        let rowElement = XMLEscaping.elementName(settings.rowElementName)
        let rowIndent = indent + indent
        let cellIndent = rowIndent + indent

        for try await streamElement in dataSource.streamRows(for: table) {
            try progress.checkCancellation()
            switch streamElement {
            case .header(let header):
                columns = header.columns.map { XMLEscaping.elementName($0) }
            case .rows(let rows):
                for row in rows {
                    try fileHandle.write(contentsOf: "\(rowIndent)<\(rowElement)>\(newline)".toUTF8Data())
                    for (index, value) in row.enumerated() where index < columns.count {
                        let markup = cellMarkup(column: columns[index], value: value)
                        try fileHandle.write(contentsOf: "\(cellIndent)\(markup)\(newline)".toUTF8Data())
                    }
                    try fileHandle.write(contentsOf: "\(rowIndent)</\(rowElement)>\(newline)".toUTF8Data())
                    progress.incrementRow()
                }
            }
        }
    }

    private func cellMarkup(column: String, value: PluginCellValue) -> String {
        switch value {
        case .null:
            return settings.marksNulls
                ? "<\(column) xsi:nil=\"true\"/>"
                : "<\(column)></\(column)>"
        case .bytes(let data):
            return "<\(column)>\(data.base64EncodedString())</\(column)>"
        case .text(let text):
            return "<\(column)>\(XMLEscaping.text(text))</\(column)>"
        }
    }
}
