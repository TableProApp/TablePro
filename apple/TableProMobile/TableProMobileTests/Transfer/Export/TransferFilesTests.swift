import Foundation
import Testing
@testable import TableProMobile

struct TransferFilesTests {
    @Test("A name that holds a path separator or a colon keeps its other letters")
    func separatorsBecomeUnderscores() {
        #expect(TransferFiles.sanitizedFileName("a/b") == "a_b")
        #expect(TransferFiles.sanitizedFileName("a\\b:c") == "a_b_c")
        #expect(TransferFiles.sanitizedFileName("line\nbreak") == "line_break")
    }

    @Test("A name of dots, spaces or nothing falls back, so it never names a folder or a hidden file")
    func dotNamesFallBack() {
        #expect(TransferFiles.sanitizedFileName("..") == "Export")
        #expect(TransferFiles.sanitizedFileName(".") == "Export")
        #expect(TransferFiles.sanitizedFileName("   ") == "Export")
        #expect(TransferFiles.sanitizedFileName("") == "Export")
        #expect(TransferFiles.sanitizedFileName(".hidden") == "hidden")
    }

    @Test("A long name is cut on a character boundary under the byte limit")
    func longNamesAreCut() {
        let name = String(repeating: "日本", count: 200)
        let cleaned = TransferFiles.sanitizedFileName(name)
        #expect(cleaned.utf8.count <= TransferFiles.maximumNameBytes)
        #expect(cleaned.allSatisfy { $0 == "日" || $0 == "本" })
        #expect(TransferFiles.sanitizedFileName("Cafe\u{301} orders") == "Cafe\u{301} orders")
    }

    @Test("A long imported name is cut in its stem, so its extension and a gzip's inner one survive")
    func longImportNamesKeepTheirExtensions() {
        let stem = String(repeating: "a", count: 201)
        let gzipped = TransferFiles.sanitizedFileNameKeepingExtension("\(stem).sql.gz", fallback: "Import")
        #expect(gzipped == String(repeating: "a", count: TransferFiles.maximumNameBytes - 7) + ".sql.gz")
        #expect(SQLImportFile.isCompressed(URL(fileURLWithPath: "/tmp/\(gzipped)")))
        let plain = TransferFiles.sanitizedFileNameKeepingExtension("\(stem).CSV", fallback: "Import")
        #expect(plain == String(repeating: "a", count: TransferFiles.maximumNameBytes - 4) + ".CSV")
        #expect(TransferFiles.sanitizedFileNameKeepingExtension("orders.2024.csv", fallback: "Import") == "orders.2024.csv")
        #expect(TransferFiles.sanitizedFileNameKeepingExtension("../x.sql", fallback: "Import") == "_x.sql")
        #expect(TransferFiles.sanitizedFileNameKeepingExtension(".gz", fallback: "Import") == "gz")
        #expect(TransferFiles.sanitizedFileNameKeepingExtension("", fallback: "Import") == "Import")
    }

    @Test("The export file sits in its folder under the clean name with the format's extension")
    func fileURLUsesTheCleanName() {
        let folder = URL(fileURLWithPath: "/tmp/x", isDirectory: true)
        #expect(TransferFiles.fileURL(in: folder, name: "a/b", fileExtension: "csv").lastPathComponent == "a_b.csv")
        #expect(TransferFiles.fileURL(in: folder, name: "..", fileExtension: "sql").lastPathComponent == "Export.sql")
    }

    @Test("The sweep removes what an earlier run left in its roots")
    func sweepRemovesLeftovers() throws {
        let root = try TransferTestFolders.make("sweep")
        let exports = root.appendingPathComponent("Exports", isDirectory: true)
        let folder = try TransferFiles.makeExportFolder(in: exports)
        try Data("x".utf8).write(to: folder.appendingPathComponent("left.csv"))

        TransferFiles.sweep(roots: [exports])

        #expect(!FileManager.default.fileExists(atPath: exports.path))
        TransferFiles.remove(root)
    }

    @Test("A SQL export's split parts are shared after the main file, in part order")
    func writtenFilesListsPartsAfterThePrimary() throws {
        let folder = try TransferTestFolders.make("parts")
        let primary = folder.appendingPathComponent("dump.sql")
        for name in ["dump.part10.sql", "dump.sql", "dump.part2.sql"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }

        let names = TransferFiles.writtenFiles(in: folder, primary: primary).map(\.lastPathComponent)

        #expect(names == ["dump.sql", "dump.part2.sql", "dump.part10.sql"])
        TransferFiles.remove(folder)
    }
}
