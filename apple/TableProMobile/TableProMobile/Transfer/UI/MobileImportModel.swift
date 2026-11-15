import Foundation
import Observation
import TableProDatabase
import TableProModels
import TableProPluginKit

// Where an import lands, read once when the sheet opens: a switch in another window cannot move it mid-sheet.
nonisolated struct ImportTargetContext: Sendable {
    let connectionId: UUID
    let connectionName: String
    let databaseType: DatabaseType
    let database: String?
    let schema: String?
    // What a catalog read opens on: the active database where the engine switches databases, else "".
    let catalogDatabase: String
    let safeModeLevel: SafeModeLevel
    let serverVersion: String?
}

nonisolated struct ImportFinishedSummary: Equatable, Sendable {
    let succeeded: Bool
    let headline: String
    let lines: [String]
    let transactionMessage: String?

    init(_ outcome: DataImportOutcome) {
        switch outcome.ending {
        case .completed:
            succeeded = true
            headline = String(localized: "Import Complete")
        case .stopped:
            succeeded = false
            headline = String(localized: "Import Stopped")
        case .expired:
            succeeded = false
            headline = String(localized: "Import stopped when TablePro moved to the background.")
        case .failed(let message):
            succeeded = false
            headline = message
        }
        lines = outcome.summaryLines
        transactionMessage = outcome.transactionMessage
    }
}

// A file already copied into tmp/Imports by an earlier sheet, handed on when the person picks another connection.
nonisolated enum ImportFileHandoff {
    static func staged(_ url: URL) -> StagedImportFile? {
        let root = TransferFiles.importsDirectory.standardizedFileURL.path
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == root else { return nil }
        return StagedImportFile(url: url, folder: folder, originalName: url.lastPathComponent)
    }

    static func stage(_ url: URL) async throws -> StagedImportFile {
        if let staged = staged(url) { return staged }
        return try await ImportFileStaging.stage(url)
    }
}

// The staging, the confirmation, the run and the stop question every import sheet goes through. The row and SQL file
// sheets own one and add what they ask before it.
@MainActor
@Observable
final class ImportRunController {
    enum Phase: Equatable {
        case staging
        case configuring
        case running(TransferProgress)
        case finished(ImportFinishedSummary)
        case failed(String)
    }

    let context: ImportTargetContext
    let plugin: any ImportFormatPlugin
    let sourceURL: URL
    private(set) var phase: Phase = .staging
    private(set) var file: StagedImportFile?
    private(set) var stopQuestion: ImportStopQuestion?
    private(set) var confirmationMessage: String?
    private(set) var blockedMessage: String?

    @ObservationIgnored private let host: any TransferSessionHost
    @ObservationIgnored private let connectionManager: ConnectionManager
    @ObservationIgnored private var gate = ConfirmedWriteGate<ImportRequest>()
    @ObservationIgnored private var confirmedRequest: ImportRequest?
    @ObservationIgnored private var run: ImportRun?
    @ObservationIgnored private var runGeneration = 0
    @ObservationIgnored private var keepsFile = false
    @ObservationIgnored var willBegin: (@MainActor (ImportRequest) -> Void)?
    @ObservationIgnored var onFinished: (@MainActor () -> Void)?

    init(
        sourceURL: URL,
        plugin: any ImportFormatPlugin,
        context: ImportTargetContext,
        host: any TransferSessionHost,
        connectionManager: ConnectionManager
    ) {
        self.sourceURL = sourceURL
        self.plugin = plugin
        self.context = context
        self.host = host
        self.connectionManager = connectionManager
    }

    var refusal: String? {
        ImportRun.refusal(
            connectionName: context.connectionName,
            databaseType: context.databaseType,
            safeModeLevel: context.safeModeLevel,
            formatId: type(of: plugin).formatId
        )
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var isConfiguring: Bool {
        if case .configuring = phase { return true }
        return false
    }

    var fileName: String {
        file?.originalName ?? sourceURL.lastPathComponent
    }

    // True once the copy exists, whether this call made it or an earlier one did.
    func stageIfNeeded() async -> Bool {
        if file != nil { return true }
        guard case .staging = phase else { return false }
        do {
            file = try await ImportFileHandoff.stage(sourceURL)
            phase = .configuring
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    // `extraConfirmation` is asked on top of Safe Mode's question: emptying the table first cannot be taken back.
    func requestImport(_ request: ImportRequest, extraConfirmation: String? = nil) {
        guard refusal == nil, isConfiguring else { return }
        switch gate.submit(request, under: context.safeModeLevel) {
        case .run(let approved):
            if let extraConfirmation {
                confirmedRequest = approved
                confirmationMessage = extraConfirmation
            } else {
                begin(approved)
            }
        case .awaitConfirmation:
            confirmationMessage = extraConfirmation
                ?? String(localized: "This import will modify data. Are you sure you want to continue?")
        case .blocked:
            blockedMessage = refusal
                ?? String(localized: "This connection is in read-only mode. Write queries are not allowed.")
        }
    }

    func confirmImport() {
        confirmationMessage = nil
        if let request = confirmedRequest {
            confirmedRequest = nil
            begin(request)
        } else if let request = gate.confirm(under: context.safeModeLevel) {
            begin(request)
        }
    }

    func cancelConfirmation() {
        confirmationMessage = nil
        confirmedRequest = nil
        gate.cancel()
    }

    func dismissBlocked() {
        blockedMessage = nil
    }

    private func begin(_ request: ImportRequest) {
        willBegin?(request)
        let background = TransferBackgroundRun(
            title: String(format: String(localized: "Importing %@"), fileName),
            connectionManager: connectionManager,
            connectionId: context.connectionId
        )
        let run = ImportRun(request: request, plugin: plugin, host: host, background: background)
        self.run = run
        runGeneration += 1
        let generation = runGeneration
        phase = .running(TransferProgress(stage: .preparing))
        Task { [weak self] in
            do {
                let outcome = try await run.run { [weak self] progress in
                    Task { @MainActor in self?.progressArrived(progress, generation: generation) }
                }
                self?.complete(outcome, generation: generation)
            } catch {
                self?.fail(error, generation: generation)
            }
        }
    }

    private func progressArrived(_ progress: TransferProgress, generation: Int) {
        guard generation == runGeneration, isRunning else { return }
        phase = .running(progress)
    }

    private func complete(_ outcome: DataImportOutcome, generation: Int) {
        guard generation == runGeneration else { return }
        run = nil
        stopQuestion = nil
        phase = .finished(ImportFinishedSummary(outcome))
        onFinished?()
    }

    private func fail(_ error: any Error, generation: Int) {
        guard generation == runGeneration else { return }
        run = nil
        stopQuestion = nil
        if let refusal = error as? MobileTransferRefusal {
            phase = .failed(refusal.reason)
        } else if let appError = error as? AppError {
            phase = .failed([appError.message, appError.recovery].compactMap { $0 }.joined(separator: " "))
        } else if error is CancellationError {
            phase = .failed(String(localized: "The import was cancelled. No rows were changed."))
        } else {
            phase = .failed(error.localizedDescription)
        }
        onFinished?()
    }

    // MARK: - Stop

    func requestStop() {
        guard let run, isRunning else { return }
        stopQuestion = run.stopQuestion
    }

    func answerStop(_ choice: ImportStopChoice?) {
        stopQuestion = nil
        guard let choice, let run else { return }
        run.stop(choice)
    }

    // MARK: - Close

    // The copy goes with the sheet unless another connection's sheet takes it over.
    func handOffFile() -> URL? {
        guard !isRunning else { return nil }
        keepsFile = file != nil
        return file?.url ?? sourceURL
    }

    func close() {
        guard !isRunning, !keepsFile else { return }
        file?.discard()
        file = nil
    }
}
