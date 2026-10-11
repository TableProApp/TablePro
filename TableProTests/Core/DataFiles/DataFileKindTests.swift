//
//  DataFileKindTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct DataFileKindTests {
    private func kind(_ name: String) -> DataFileKind? {
        DataFileKind.classify(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    @Test("A compressed file is judged by the extension inside it")
    func compressedUsesInnerExtension() throws {
        let csv = try #require(kind("export.csv.gz"))
        #expect(csv.format == .delimited)
        #expect(csv.isCompressed)
        #expect(!csv.isEditable)
        #expect(csv.typeIdentifier == DataFileKind.gzipType)
        #expect(kind("dump.sql.gz") == nil)
        #expect(kind("book.xlsx.gz") == nil)
        #expect(kind("archive.gz") == nil)
    }

    @Test("Each extension maps to its format and type")
    func extensionsMapToTypes() {
        let expected: [(name: String, format: DataFileFormat, type: String)] = [
            ("a.csv", .delimited, DataFileKind.commaSeparatedType),
            ("a.tsv", .delimited, DataFileKind.tabSeparatedType),
            ("a.tab", .delimited, DataFileKind.tabSeparatedType),
            ("a.psv", .delimited, DataFileKind.pipeSeparatedType),
            ("a.txt", .delimited, DataFileKind.plainTextType),
            ("a.dat", .delimited, DataFileKind.dataType),
            ("a.json", .json, DataFileKind.jsonType),
            ("a.jsonl", .jsonLines, DataFileKind.jsonLinesType),
            ("a.ndjson", .jsonLines, DataFileKind.newlineDelimitedJSONType),
            ("a.xlsx", .workbook, DataFileKind.workbookType)
        ]
        for entry in expected {
            let classified = kind(entry.name)
            #expect(classified?.format == entry.format, "\(entry.name)")
            #expect(classified?.typeIdentifier == entry.type, "\(entry.name)")
        }
    }

    @Test("A workbook is read-only and saves as CSV")
    func workbookSavesAsCSV() throws {
        let workbook = try #require(kind("book.xlsx"))
        #expect(!workbook.isEditable)
        #expect(workbook.saveTypeIdentifier == DataFileKind.commaSeparatedType)
    }

    @Test("Every editable type is also readable and has a save format")
    func editableTypesSave() {
        for type in DataFileKind.editableTypes {
            #expect(DataFileKind.readableTypes.contains(type), "\(type)")
            #expect(DataFileKind.format(forSaveType: type) != nil, "\(type)")
            #expect(DataFileKind.fileExtension(forType: type) != nil, "\(type)")
        }
    }

    @Test("A type identifier alone still names a kind")
    func typeIdentifierWithoutURL() {
        #expect(DataFileKind.kind(forTypeIdentifier: DataFileKind.newlineDelimitedJSONType, url: nil)?.format == .jsonLines)
        #expect(DataFileKind.kind(forTypeIdentifier: DataFileKind.pipeSeparatedType, url: nil)?.contentExtension == "psv")
        #expect(DataFileKind.kind(forTypeIdentifier: "public.png", url: nil) == nil)
    }
}
