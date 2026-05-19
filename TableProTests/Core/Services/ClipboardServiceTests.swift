//
//  ClipboardServiceTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing
import UniformTypeIdentifiers

@MainActor
@Suite("ClipboardService pasteboard")
struct ClipboardServiceTests {
    private static let csvType = NSPasteboard.PasteboardType("public.comma-separated-values-text")
    private static let tsvType = NSPasteboard.PasteboardType("public.utf8-tab-separated-values-text")
    private static let gridRowsType = NSPasteboard.PasteboardType("com.TablePro.gridRows")

    @Test("writeCsv writes string, utf8PlainText, and the CSV UTI")
    func writeCsvWritesCsvUti() {
        let provider = NSPasteboardClipboardProvider()
        let csv = "id,name\n1,alice\n"
        provider.writeCsv(csv)

        let pb = NSPasteboard.general
        #expect(pb.string(forType: .string) == csv)
        #expect(pb.string(forType: NSPasteboard.PasteboardType(UTType.utf8PlainText.identifier)) == csv)
        #expect(pb.string(forType: Self.csvType) == csv)
    }

    @Test("writeCsv does not write the gridRows marker (CSV is not a grid paste)")
    func writeCsvSkipsGridRowsMarker() {
        let provider = NSPasteboardClipboardProvider()
        provider.writeCsv("a,b\n")
        let pb = NSPasteboard.general
        #expect(pb.types?.contains(Self.gridRowsType) != true)
    }

    @Test("writeCsv does not write the TSV UTI (avoids spreadsheet auto-paste-as-TSV)")
    func writeCsvSkipsTsvUti() {
        let provider = NSPasteboardClipboardProvider()
        provider.writeCsv("a,b\n")
        let pb = NSPasteboard.general
        #expect(pb.string(forType: Self.tsvType) == nil)
    }
}
