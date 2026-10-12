//
//  ImportFilePanel.swift
//  TablePro
//

import AppKit
import os
import UniformTypeIdentifiers

/// The file panel behind every import command, and the only place a chosen file is accepted.
///
/// `allowedContentTypes` dims a file it does not name, but it does not stop one being chosen.
/// Measured on macOS 27 with `[org.iso.sql, org.gnu.gnu-zip-archive]`: a single click on a dimmed
/// `.csv` leaves Open disabled, and a double-click in list view selects it, enables Open, and
/// returns it from `runModal()`. That is how a CSV reached the statement importer and was parsed as
/// SQL (#3047). `panel(_:shouldEnable:)` cannot close it either, because AppKit ANDs it with
/// `allowedContentTypes` and it can only narrow. `panel(_:validate:)` is the gate: throwing from it
/// shows the error and leaves the panel open on the file the user picked.
@MainActor
internal enum ImportFilePanel {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportFilePanel")

    /// Import Data… and the statement dialog's Change File…, where the format follows the file. A
    /// file no offered format reads is refused here rather than handed to the wrong one.
    internal static func present(
        matching options: [ImportFormatOption],
        message: String,
        in window: NSWindow?
    ) async -> URL? {
        await present(
            contentTypes: ImportFileFormatResolver.contentTypes(for: options),
            gate: ImportFileGate(options: options),
            message: message,
            in: window
        )
    }

    /// Import Data From > a named format, and the object browser's own import items. The user has
    /// already said what the file holds, so every file is enabled and nothing is read off the
    /// extension. That is the route for a CSV called `orders.txt` or carrying no extension at all.
    internal static func presentForNamedFormat(
        message: String,
        in window: NSWindow?
    ) async -> URL? {
        await present(contentTypes: [], gate: nil, message: message, in: window)
    }

    private static func present(
        contentTypes: [UTType],
        gate: ImportFileGate?,
        message: String,
        in window: NSWindow?
    ) async -> URL? {
        guard let window else {
            logger.warning("No host window, cannot present the import file panel")
            return nil
        }

        let panel = NSOpenPanel()
        /// An empty list is AppKit's own "enable every file", per NSSavePanel.h.
        panel.allowedContentTypes = contentTypes
        /// After `allowedContentTypes`: macOS 27 rewrites both from it.
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = message

        panel.delegate = gate
        let response = await panel.presentAsSheet(for: window)
        withExtendedLifetime(gate) {}

        guard response == .OK else { return nil }
        return panel.url
    }
}

/// Refuses a file no offered format reads. `NSSavePanel.delegate` is weak, so the caller holds this
/// alive for the life of the panel.
@MainActor
private final class ImportFileGate: NSObject, NSOpenSavePanelDelegate {
    private let options: [ImportFormatOption]

    init(options: [ImportFormatOption]) {
        self.options = options
    }

    func panel(_ sender: Any, validate url: URL) throws {
        switch ImportFileFormatResolver.match(url, among: options) {
        case .format:
            return
        case .compressedRowFormat(let formatId):
            throw ImportFileGateError.compressedRowFormat(
                fileName: url.lastPathComponent,
                formatName: formatName(for: formatId)
            )
        case .ambiguous(let formatIds):
            throw ImportFileGateError.ambiguous(
                fileName: url.lastPathComponent,
                formatNames: formatIds.map(formatName(for:))
            )
        case .unrecognized:
            throw ImportFileGateError.unrecognized(
                fileName: url.lastPathComponent,
                extensions: ImportFileFormatResolver.acceptedExtensions(for: options)
            )
        }
    }

    private func formatName(for formatId: String) -> String {
        options.first { $0.id == formatId }?.name ?? formatId
    }
}

private enum ImportFileGateError: LocalizedError {
    case unrecognized(fileName: String, extensions: [String])
    case compressedRowFormat(fileName: String, formatName: String)
    case ambiguous(fileName: String, formatNames: [String])

    var errorDescription: String? {
        switch self {
        case .unrecognized(let fileName, _):
            return String(format: String(localized: "There is no import format for “%@”."), fileName)
        case .compressedRowFormat(let fileName, _):
            return String(format: String(localized: "“%@” is compressed."), fileName)
        case .ambiguous(let fileName, _):
            return String(format: String(localized: "More than one format reads “%@”."), fileName)
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unrecognized(_, let extensions):
            let list = extensions.map { ".\($0)" }.joined(separator: ", ")
            return String(format: String(localized: "This connection imports %@."), list)
        case .compressedRowFormat(_, let formatName):
            return String(
                format: String(localized: "Only a SQL dump is read compressed. Expand it first, then import the %@."),
                formatName
            )
        case .ambiguous(_, let formatNames):
            return String(
                format: String(localized: "Name the one you want under File > Import > Import Data From: %@."),
                formatNames.joined(separator: ", ")
            )
        }
    }
}
