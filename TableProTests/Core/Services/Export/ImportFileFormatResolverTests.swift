//
//  ImportFileFormatResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing
import UniformTypeIdentifiers

/// The four bundled importers, spelled here rather than read from `PluginManager` because plugins
/// never load under XCTest.
struct ImportFileFormatResolverTests {
    private let sql = ImportFormatOption(id: "sql", name: "SQL", acceptedFileExtensions: ["sql", "gz"])
    private let csv = ImportFormatOption(id: "csv", name: "CSV", acceptedFileExtensions: ["csv", "tsv"])
    private let json = ImportFormatOption(id: "json", name: "JSON", acceptedFileExtensions: ["json", "jsonl", "ndjson"])
    private let xlsx = ImportFormatOption(id: "xlsx", name: "XLSX", acceptedFileExtensions: ["xlsx"])

    private var allFormats: [ImportFormatOption] { [sql, csv, json, xlsx] }

    private func match(_ name: String, among options: [ImportFormatOption]? = nil) -> ImportFileFormatMatch {
        ImportFileFormatResolver.match(
            URL(fileURLWithPath: "/tmp/\(name)"),
            among: options ?? allFormats
        )
    }

    // MARK: - Every offered format is reachable

    @Test("Each extension resolves to the format that reads it")
    func extensionResolvesToItsFormat() {
        let cases: [(name: String, formatId: String)] = [
            ("orders.csv", "csv"),
            ("orders.tsv", "csv"),
            ("orders.json", "json"),
            ("orders.jsonl", "json"),
            ("orders.ndjson", "json"),
            ("orders.xlsx", "xlsx"),
            ("dump.sql", "sql"),
        ]
        for testCase in cases {
            #expect(match(testCase.name) == .format(testCase.formatId), "\(testCase.name)")
        }
    }

    @Test("A CSV is never resolved as SQL, which is the reported defect")
    func csvIsNotSql() {
        #expect(match("orders.csv") != .format("sql"))
    }

    @Test("An uppercase extension resolves the same way")
    func extensionMatchIsCaseInsensitive() {
        #expect(match("ORDERS.CSV") == .format("csv"))
        #expect(match("Dump.SQL") == .format("sql"))
    }

    // MARK: - Ordering

    @Test("Resolution does not depend on the order the formats are offered")
    func resolutionIgnoresFormatOrder() {
        #expect(match("orders.csv", among: [sql, csv, json, xlsx]) == .format("csv"))
        #expect(match("orders.csv", among: [xlsx, json, csv, sql]) == .format("csv"))
        #expect(match("dump.sql", among: [xlsx, json, csv, sql]) == .format("sql"))
    }

    // MARK: - Compressed files

    @Test("A bare .gz belongs to whichever format reads compressed files")
    func bareArchiveResolvesToTheCompressedReader() {
        #expect(match("archive.gz") == .format("sql"))
    }

    @Test("A compressed dump resolves through its inner extension")
    func compressedDumpResolvesToSql() {
        #expect(match("dump.sql.gz") == .format("sql"))
    }

    @Test("A compressed row-format file is named rather than parsed as SQL")
    func compressedRowFormatIsReported() {
        #expect(match("orders.csv.gz") == .compressedRowFormat(formatId: "csv"))
        #expect(match("orders.xlsx.gz") == .compressedRowFormat(formatId: "xlsx"))
    }

    @Test("A suffix no format claims stays with the compressed reader")
    func compressedUnknownStaysWithTheCompressedReader() {
        #expect(match("dump.v1.gz") == .format("sql"))
        #expect(match("backup.tar.gz") == .format("sql"))
    }

    @Test("A leading-dot name is read off the file name, not the path extension")
    func leadingDotCompressedNameIsStillRefused() {
        #expect(match(".csv.gz") == .compressedRowFormat(formatId: "csv"))
        #expect(match(".sql.gz") == .format("sql"))
    }

    @Test("An uppercase compressed dump resolves and is still recognized as compressed")
    func uppercaseCompressedDumpIsExpanded() {
        #expect(match("DUMP.SQL.GZ") == .format("sql"))
        #expect(match("ORDERS.CSV.GZ") == .compressedRowFormat(formatId: "csv"))
        #expect(FileDecompressor.isCompressed(URL(fileURLWithPath: "/tmp/DUMP.SQL.GZ")))
        #expect(FileDecompressor.isCompressed(URL(fileURLWithPath: "/tmp/dump.sql.gz")))
        #expect(FileDecompressor.isCompressed(URL(fileURLWithPath: "/tmp/dump.sql")) == false)
    }

    @Test("Nothing reads .gz means a compressed file resolves to nothing")
    func compressedWithoutACompressedReaderIsUnrecognized() {
        #expect(match("dump.sql.gz", among: [csv, json, xlsx]) == .unrecognized)
        #expect(match("archive.gz", among: [csv, json, xlsx]) == .unrecognized)
    }

    // MARK: - Two formats claiming one extension

    @Test("An extension two formats read is named rather than resolved by offer order")
    func overlappingExtensionIsReportedAmbiguous() {
        let rival = ImportFormatOption(id: "rival", name: "Rival", acceptedFileExtensions: ["csv"])
        #expect(match("orders.csv", among: [csv, rival]) == .ambiguous(formatIds: ["csv", "rival"]))
        #expect(match("orders.csv", among: [rival, csv]) == .ambiguous(formatIds: ["rival", "csv"]))
    }

    @Test("A second format claiming gz makes a compressed file ambiguous too")
    func overlappingCompressedExtensionIsReportedAmbiguous() {
        let rival = ImportFormatOption(id: "rival", name: "Rival", acceptedFileExtensions: ["gz"])
        #expect(match("dump.sql.gz", among: [sql, rival]) == .ambiguous(formatIds: ["sql", "rival"]))
        #expect(match("archive.gz", among: [sql, rival]) == .ambiguous(formatIds: ["sql", "rival"]))
    }

    @Test("A row format claimed twice is still refused as compressed, not resolved")
    func overlappingInnerSuffixDoesNotResolve() {
        let rival = ImportFormatOption(id: "rival", name: "Rival", acceptedFileExtensions: ["csv"])
        #expect(match("orders.csv.gz", among: [sql, csv, rival]) == .format("sql"))
    }

    // MARK: - Files no format reads

    @Test("An extension no format reads is refused")
    func unknownExtensionIsUnrecognized() {
        #expect(match("notes.txt") == .unrecognized)
        #expect(match("archive.zip") == .unrecognized)
    }

    @Test("A file with no extension is refused")
    func missingExtensionIsUnrecognized() {
        #expect(match("orders") == .unrecognized)
    }

    @Test("A format the connection does not offer is refused")
    func formatNotOfferedIsUnrecognized() {
        #expect(match("orders.csv", among: [sql]) == .unrecognized)
        #expect(match("dump.sql", among: [csv, json, xlsx]) == .unrecognized)
    }

    @Test("No format offered means nothing resolves")
    func emptyFormatListResolvesNothing() {
        #expect(match("dump.sql", among: []) == .unrecognized)
        #expect(match("archive.gz", among: []) == .unrecognized)
    }

    // MARK: - What the panel is built from

    @Test("The panel's content types are the union of every offered format")
    func contentTypesCoverEveryOfferedFormat() {
        let identifiers = Set(ImportFileFormatResolver.contentTypes(for: allFormats).map(\.identifier))
        #expect(identifiers.contains("public.comma-separated-values-text"))
        #expect(identifiers.contains("public.tab-separated-values-text"))
        #expect(identifiers.contains("public.json"))
        #expect(identifiers.contains("org.openxmlformats.spreadsheetml.sheet"))
        #expect(identifiers.contains("org.iso.sql"))
        #expect(identifiers.contains("org.gnu.gnu-zip-archive"))
    }

    @Test("The content types are not a function of which format is offered first")
    func contentTypesIgnoreFormatOrder() {
        let forward = Set(ImportFileFormatResolver.contentTypes(for: allFormats).map(\.identifier))
        let reversed = Set(ImportFileFormatResolver.contentTypes(for: allFormats.reversed()).map(\.identifier))
        #expect(forward == reversed)
    }

    @Test("One format alone contributes only its own types")
    func contentTypesFollowTheOfferedFormats() {
        let identifiers = Set(ImportFileFormatResolver.contentTypes(for: [sql]).map(\.identifier))
        #expect(identifiers.contains("org.iso.sql"))
        #expect(identifiers.contains("public.comma-separated-values-text") == false)
    }

    @Test("A duplicated extension contributes one type")
    func contentTypesAreDeduplicated() {
        let duplicate = ImportFormatOption(id: "other", name: "Other", acceptedFileExtensions: ["csv"])
        let types = ImportFileFormatResolver.contentTypes(for: [csv, duplicate])
        #expect(types.count == Set(types.map(\.identifier)).count)
    }

    // MARK: - What a refusal names

    @Test("The accepted extensions are every offered format's, lowercased and deduplicated")
    func acceptedExtensionsListEveryFormat() {
        let extensions = ImportFileFormatResolver.acceptedExtensions(for: allFormats)
        #expect(extensions == ["sql", "gz", "csv", "tsv", "json", "jsonl", "ndjson", "xlsx"])
    }

    @Test("A duplicated extension is listed once")
    func acceptedExtensionsAreDeduplicated() {
        let duplicate = ImportFormatOption(id: "other", name: "Other", acceptedFileExtensions: ["CSV"])
        #expect(ImportFileFormatResolver.acceptedExtensions(for: [csv, duplicate]) == ["csv", "tsv"])
    }
}
