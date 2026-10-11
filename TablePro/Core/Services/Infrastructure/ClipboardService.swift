//
//  ClipboardService.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import TableProTextEngine
import UniformTypeIdentifiers

struct GridRowsClipboardPayload: Codable, Equatable {
    let columns: [String]
    let rows: [[PluginCellValue]]
    /// Row index to the columns that row has no field for, so a paste leaves them missing.
    var absentCells: [Int: Set<Int>]?
}

extension GridRowsClipboardPayload {
    /// Rows copied out of a grid, in the columns the copy carries. Every copy builds its payload
    /// here, so the fields a row has none of travel with its values rather than each copy path
    /// deciding for itself whether to carry them.
    init(columns: [String], copying copiedRows: [Row], projection: VisibleColumnProjection) {
        var absentCells: [Int: Set<Int>] = [:]
        for (index, row) in copiedRows.enumerated() {
            let absent = projection.absentColumns(row.absentColumns)
            if !absent.isEmpty { absentCells[index] = absent }
        }
        self.init(
            columns: columns,
            rows: copiedRows.map { projection.values(Array($0.values)) },
            absentCells: absentCells.isEmpty ? nil : absentCells
        )
    }
}

protocol ClipboardProvider {
    func readText() -> String?
    func readGridRows() -> GridRowsClipboardPayload?
    func writeText(_ text: String)
    func writeCsv(_ csv: String)
    func writeImage(_ image: NSImage)
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload)
    var hasText: Bool { get }
    var hasGridRows: Bool { get }
}

extension ClipboardProvider {
    /// Text a clipboard-history app should not retain. Providers that cannot express that
    /// fall back to a plain write rather than refusing to copy.
    func writeSecretText(_ text: String) {
        writeText(text)
    }
}

struct NSPasteboardClipboardProvider: ClipboardProvider {
    private static let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    private static let csvType = NSPasteboard.PasteboardType("public.comma-separated-values-text")
    private static let gridRowsType = NSPasteboard.PasteboardType("com.TablePro.gridRows")

    /// The convention clipboard managers watch for to keep an item out of their history.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Resolves through `PasteboardTextReader` so a clipboard that carries text as HTML, RTF or a
    /// file URL still pastes. Reading `.string` alone returned nil for those and the caller had no
    /// way to tell that apart from an empty clipboard.
    func readText() -> String? {
        PasteboardTextReader.plainText()
    }

    func readGridRows() -> GridRowsClipboardPayload? {
        guard let data = NSPasteboard.general.data(forType: Self.gridRowsType) else { return nil }
        return try? JSONDecoder().decode(GridRowsClipboardPayload.self, from: data)
    }

    func writeText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(text, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
    }

    func writeSecretText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString(text, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
        pb.setString(text, forType: Self.concealedType)
    }

    func writeCsv(_ csv: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(csv, forType: .string)
        pb.setString(csv, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
        pb.setString(csv, forType: Self.csvType)
    }

    /// An image goes on the pasteboard as an image, so it pastes into a document rather than
    /// arriving as the hex or the markup a plain copy of the same cell would give.
    func writeImage(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
    }

    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
        pb.setString(tsv, forType: Self.tsvType)
        if let html {
            pb.setString(html, forType: .html)
        }
        if let data = try? JSONEncoder().encode(gridRows) {
            pb.setData(data, forType: Self.gridRowsType)
        }
    }

    var hasText: Bool {
        PasteboardTextReader.hasText()
    }

    var hasGridRows: Bool {
        NSPasteboard.general.types?.contains(Self.gridRowsType) == true
    }
}

@MainActor
enum ClipboardService {
    static var shared: ClipboardProvider = NSPasteboardClipboardProvider()
}
