//
//  ClipboardService.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import UniformTypeIdentifiers

struct GridRowsClipboardPayload: Codable, Equatable {
    let columns: [String]
    let rows: [[PluginCellValue]]
}

protocol ClipboardProvider {
    func readText() -> String?
    func readGridRows() -> GridRowsClipboardPayload?
    func writeText(_ text: String)
    func writeCsv(_ csv: String)
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload)
    var hasText: Bool { get }
    var hasGridRows: Bool { get }
}

struct NSPasteboardClipboardProvider: ClipboardProvider {
    private static let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    private static let csvType = NSPasteboard.PasteboardType("public.comma-separated-values-text")
    private static let gridRowsType = NSPasteboard.PasteboardType("com.TablePro.gridRows")

    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
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

    func writeCsv(_ csv: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(csv, forType: .string)
        pb.setString(csv, forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier))
        pb.setString(csv, forType: Self.csvType)
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
        NSPasteboard.general.string(forType: .string) != nil
    }

    var hasGridRows: Bool {
        NSPasteboard.general.types?.contains(Self.gridRowsType) == true
    }
}

@MainActor
enum ClipboardService {
    static var shared: ClipboardProvider = NSPasteboardClipboardProvider()
}
