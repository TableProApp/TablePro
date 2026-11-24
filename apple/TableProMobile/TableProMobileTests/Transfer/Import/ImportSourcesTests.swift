import Foundation
import TableProGzip
@testable import TableProMobile
import TableProModels
import TableProPluginKit
import TableProSQLFile
import TableProTestSupport
import Testing

struct ImportSourcesTests {
    private static let script = "CREATE TABLE t (a int);\nINSERT INTO t VALUES (1);\nINSERT INTO t VALUES ('x;y');\n"

    private func gzipped(in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("dump.sql.gz")
        try GzipDeflater.compress(Data(Self.script.utf8)).write(to: url)
        return url
    }

    @Test("A gzipped dump is expanded beside its copy, split into its statements, and the expansion removed")
    func gzipDumpSplitsIntoStatements() async throws {
        let folder = try TransferTestFolders.make("sql-gz")
        let source = MobileSQLFileImportSource(
            url: try gzipped(in: folder),
            encoding: .utf8,
            family: .other,
            grammar: { SQLImportFile.grammar(for: .sqlite, session: nil) }
        )

        var statements: [String] = []
        for try await element in try await source.elements() {
            statements.append(element.statementText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        #expect(statements.count == 3)
        #expect(statements.last?.contains("'x;y'") == true)
        #expect(TransferTestFolders.contents(of: folder).count == 2)

        source.cleanup()
        #expect(TransferTestFolders.contents(of: folder).map(\.lastPathComponent) == ["dump.sql.gz"])
        TransferFiles.remove(folder)
    }

    @Test("A stop during the expansion of a gzipped dump ends it at once and leaves no partial file")
    func stopEndsTheExpansion() async throws {
        let folder = try TransferTestFolders.make("sql-gz-stop")
        let started = TestGate()
        await started.open()
        let source = MobileSQLFileImportSource(
            url: try gzipped(in: folder),
            encoding: .utf8,
            family: .other,
            grammar: { SQLImportFile.grammar(for: .sqlite, session: nil) },
            expand: { _, destination in
                // As `GzipFile.decompress` does: a partial file while it runs, removed when it is cancelled.
                try Data("CREATE TABLE".utf8).write(to: destination)
                await started.enter()
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw error
                }
            }
        )

        let reading = Task { _ = try await source.elements() }
        await started.waitUntilEntered()
        #expect(TransferTestFolders.contents(of: folder).count == 2)
        source.stop()

        let ended = try #require(await BoundedCall.result(within: .seconds(5)) { await reading.result })
        #expect(throws: CancellationError.self) { try ended.get() }
        #expect(TransferTestFolders.contents(of: folder).map(\.lastPathComponent) == ["dump.sql.gz"])
        TransferFiles.remove(folder)
    }

    @Test("A stop before the dump is read keeps the real expansion from starting and leaves only the dump")
    func stopBeforeReadingExpandsNothing() async throws {
        let folder = try TransferTestFolders.make("sql-gz-early-stop")
        let source = MobileSQLFileImportSource(
            url: try gzipped(in: folder),
            encoding: .utf8,
            family: .other,
            grammar: { SQLImportFile.grammar(for: .sqlite, session: nil) }
        )
        source.stop()

        await #expect(throws: CancellationError.self) {
            _ = try await source.statements()
        }
        #expect(TransferTestFolders.contents(of: folder).map(\.lastPathComponent) == ["dump.sql.gz"])
        TransferFiles.remove(folder)
    }

    @Test("The preview and the statement count read through gzip")
    func previewAndCountReadGzip() async throws {
        let folder = try TransferTestFolders.make("sql-preview")
        let file = StagedImportFile(url: try gzipped(in: folder), folder: folder, originalName: "dump.sql.gz")

        let preview = try await SQLImportFile.preview(file, databaseType: .postgresql)
        let count = try await SQLImportFile.countStatements(file, encoding: .utf8, databaseType: .postgresql)

        #expect(preview.isCompressed)
        #expect(preview.decodes)
        #expect(preview.encoding == .utf8)
        #expect(count == 3)
        #expect(TransferTestFolders.contents(of: folder).count == 1)
        TransferFiles.remove(folder)
    }

    @Test("A dump that says it is Latin-1 and does not decode as UTF-8 is read as what it says")
    func declaredEncodingIsDetected() async throws {
        let folder = try TransferTestFolders.make("sql-latin1")
        let url = folder.appendingPathComponent("dump.sql")
        var bytes = Data("SET NAMES latin1;\nINSERT INTO t VALUES ('caf".utf8)
        bytes.append(0xE9)
        bytes.append(contentsOf: Data("');\n".utf8))
        try bytes.write(to: url)

        let preview = try await SQLImportFile.preview(
            StagedImportFile(url: url, folder: folder, originalName: "dump.sql"), databaseType: .mysql
        )

        #expect(preview.detectedEncoding == .windowsCP1252)
        #expect(preview.encoding == .windowsCP1252)
        TransferFiles.remove(folder)
    }

    @Test("A picked file is copied whole into a folder of its own and the source is left where it was")
    func stagingCopiesTheFile() async throws {
        let picked = try TransferTestFolders.make("picked")
        let root = try TransferTestFolders.make("imports")
        let source = picked.appendingPathComponent("people.csv")
        try Data("id,name\n1,Ada\n".utf8).write(to: source)

        let staged = try await ImportFileStaging.stage(source, into: root)

        #expect(try Data(contentsOf: staged.url) == Data(contentsOf: source))
        #expect(staged.url.lastPathComponent == "people.csv")
        #expect(staged.folder.deletingLastPathComponent().resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        #expect(FileManager.default.fileExists(atPath: source.path))
        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.folder.path))
        TransferFiles.remove(picked)
        TransferFiles.remove(root)
    }

    @Test("A file that is not there fails the staging and leaves no folder")
    func stagingAMissingFileLeavesNothing() async throws {
        let root = try TransferTestFolders.make("imports-missing")
        let missing = root.appendingPathComponent("gone.csv")
        await #expect(throws: ImportFileStagingError.self) {
            _ = try await ImportFileStaging.stage(missing, into: root)
        }
        #expect(TransferTestFolders.contents(of: root).isEmpty)
        TransferFiles.remove(root)
    }

    @Test("The format comes from the extension, and a compressed row file is refused")
    func formatByExtension() {
        let id = { (name: String) in
            MobileImportFormats.plugin(for: URL(fileURLWithPath: "/tmp/\(name)")).map { type(of: $0).formatId }
        }
        #expect(id("a.CSV") == "csv")
        #expect(id("a.tsv") == "csv")
        #expect(id("a.ndjson") == "json")
        #expect(id("a.xlsx") == "xlsx")
        #expect(id("a.sql") == "sql")
        #expect(id("a.sql.gz") == "sql")
        #expect(id("a.csv.gz") == nil)
        #expect(id("a.txt") == nil)
    }

    @Test("Row import and SQL files are offered by engine, and refused on Read-Only")
    func offersAndRefusals() {
        #expect(MobileImportFormats.rowFormats(for: .mongodb).isEmpty)
        #expect(MobileImportFormats.rowFormats(for: .redis).isEmpty)
        #expect(MobileImportFormats.rowFormats(for: .postgresql).map { type(of: $0).formatId } == ["csv", "json", "xlsx"])
        #expect(!MobileImportFormats.offersSQLFile(for: .mongodb))
        #expect(MobileImportFormats.offersSQLFile(for: .sqlite))

        #expect(ImportRun.refusal(connectionName: "Prod", databaseType: .postgresql, safeModeLevel: .readOnly, formatId: "csv")
            != nil)
        #expect(ImportRun.refusal(connectionName: "Prod", databaseType: .mongodb, safeModeLevel: .off, formatId: "json")
            != nil)
        #expect(ImportRun.refusal(connectionName: "Dev", databaseType: .postgresql, safeModeLevel: .confirmWrites, formatId: "csv")
            == nil)
    }

    @Test("A saved mapping keeps entries for fields another file holds")
    func mappingStoreMerges() throws {
        let suite = "transfer-mapping-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImportMappingStore(defaults: defaults)
        let key = ImportMappingStore.Key(connectionId: UUID(), database: "shop", schema: "public", table: "people")

        store.remember(["Full Name": .column("name")], fields: ["Full Name", "id"], for: key)
        store.remember(["Email": .skip], fields: ["Email", "id"], for: key)

        #expect(store.overrides(for: key) == ["Full Name": .column("name"), "Email": .skip])
        let other = ImportMappingStore.Key(connectionId: key.connectionId, database: "shop", schema: "public", table: "orders")
        #expect(store.overrides(for: other).isEmpty)
    }
}
