import Foundation
import Observation
import TableProPluginKit
import TableProTabularIO

// Run SQL File: the file's encoding (read from the file, or the person's choice), how many statements it holds, and
// the SQL import plugin's options, then the same run every import goes through.
@MainActor
@Observable
final class MobileSQLFileModel {
    let runner: ImportRunController
    // Nil reads the file as UTF-8 and falls back to what the file names or looks like.
    private(set) var chosenEncoding: TabularTextEncoding?
    private(set) var preview: SQLImportFilePreview?
    private(set) var statementCount: Int?
    private(set) var isReading = false
    private(set) var readError: String?

    @ObservationIgnored private var readGeneration = 0

    init(runner: ImportRunController) {
        self.runner = runner
    }

    var encoding: String.Encoding {
        preview?.encoding ?? chosenEncoding?.foundationEncoding ?? .utf8
    }

    var encodingName: String {
        Self.name(of: encoding)
    }

    // The person chose an encoding the file does not read in, and the read goes on in the one the file names.
    var overrideNote: String? {
        guard let chosenEncoding, let preview, preview.encoding != chosenEncoding.foundationEncoding else { return nil }
        return String(
            format: String(localized: "The file does not read as %1$@, so it is read as %2$@."),
            chosenEncoding.displayName, Self.name(of: preview.encoding)
        )
    }

    var undecodableNote: String? {
        guard let preview, !preview.decodes else { return nil }
        return String(
            format: String(localized: "Some of the file does not read as %@. Choose the encoding it was saved in."),
            Self.name(of: preview.encoding)
        )
    }

    var canRun: Bool {
        runner.isConfiguring && runner.refusal == nil && !isReading && readError == nil && statementCount != nil
    }

    func start() async {
        guard await runner.stageIfNeeded() else { return }
        await read()
    }

    func choose(_ encoding: TabularTextEncoding?) async {
        guard encoding != chosenEncoding else { return }
        chosenEncoding = encoding
        await read()
    }

    private func read() async {
        guard let file = runner.file else { return }
        readGeneration += 1
        let generation = readGeneration
        isReading = true
        readError = nil
        statementCount = nil
        defer {
            if generation == readGeneration { isReading = false }
        }
        let databaseType = runner.context.databaseType
        do {
            let preview = try await SQLImportFile.preview(
                file, databaseType: databaseType, selected: chosenEncoding?.foundationEncoding ?? .utf8
            )
            guard generation == readGeneration else { return }
            self.preview = preview
            let count = try await SQLImportFile.countStatements(file, encoding: preview.encoding, databaseType: databaseType)
            guard generation == readGeneration else { return }
            statementCount = count
        } catch {
            guard generation == readGeneration, !(error is CancellationError) else { return }
            readError = error.localizedDescription
        }
    }

    func requestRun() {
        guard canRun, let file = runner.file else { return }
        let context = runner.context
        let request = ImportRequest(
            formatId: type(of: runner.plugin).formatId,
            file: file,
            connectionId: context.connectionId,
            connectionName: context.connectionName,
            databaseType: context.databaseType,
            database: context.database,
            safeModeLevel: context.safeModeLevel,
            target: nil,
            sqlEncoding: encoding
        )
        runner.requestImport(request)
    }

    static func name(of encoding: String.Encoding) -> String {
        if let known = TabularTextEncoding.allCases.first(where: { $0.foundationEncoding == encoding }) {
            return known.displayName
        }
        return String.localizedName(of: encoding)
    }
}
