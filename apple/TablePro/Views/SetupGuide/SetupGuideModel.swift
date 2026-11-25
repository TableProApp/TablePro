//
//  SetupGuideModel.swift
//  TablePro
//

import Combine
import Foundation
import TableProImport

internal enum SetupGuideStep: Hashable, Sendable {
    case origin
    case `import`
    case firstConnection
    case options
}

internal enum SetupGuideOrigin: Hashable, Sendable {
    case command(ImportCommand)
    case newConnection
    case sample
}

internal enum SetupGuideFirstConnection: Hashable, Sendable {
    case newConnection
    case sample
}

internal enum SetupGuideEnding: Equatable, Sendable {
    case newConnection
    case sample
    case handOff(ImportHandoff)
    case command(ImportCommand)

    // A recorded choice wins; else the ids every import of this guide wrote decide, and one from a picked file never opens.
    internal static func resolve(
        recorded: SetupGuideFirstConnection?,
        importedIds: [UUID],
        origin: ImportOrigin = .ownMachineOrAccount
    ) -> SetupGuideEnding {
        switch recorded {
        case .newConnection: .newConnection
        case .sample: .sample
        case nil: .handOff(ImportOutcome(connectionIds: importedIds).handoff(from: origin))
        }
    }
}

internal enum SetupGuideImportResult: Equatable {
    case imported(ImportOutcome)
    case failed(String)

    internal var message: String {
        switch self {
        case .imported(let outcome): ImportOutcomeMessage(outcome).message
        case .failed(let reason): reason
        }
    }
}

internal enum SetupGuideImportPhase {
    case scanning
    case choosing
    case pickingFile(ForeignSourceRow)
    case notice(KeychainNotice)
    case reading(appName: String)
    // The read's id gives each source's review its own view state.
    case review(ForeignAppRead, id: UUID)
}

@MainActor
internal final class SetupGuideModel: ObservableObject {
    internal struct Dependencies {
        var probe: @Sendable () async -> Set<String>
        var scan: @Sendable (ForeignSourceScanReach) async -> [ForeignSourceRow]
        var count: @Sendable (any ForeignAppImporter) async -> ForeignSourceRow
        var read: @MainActor (any ForeignAppImporter, ForeignImportRequest) async throws -> ForeignAppRead
        var announce: @MainActor (String) -> Void
        var keyboard: @MainActor () -> KeyboardSettings
        var presetCatalog: KeyboardPresetCatalog?
        var clock: any Clock<Duration>
        var probeLimit: Duration

        @MainActor internal static var live: Dependencies {
            Dependencies(
                probe: { await ForeignSourceScanner.probe() },
                scan: { await ForeignSourceScanner.scan(reach: $0) },
                count: { await ForeignSourceScanner.countedRow(for: $0) },
                read: { importer, request in try await ForeignAppImportReader.read(importer, request: request) },
                announce: { AccessibilityAnnouncement.post($0) },
                keyboard: { AppSettingsManager.shared.keyboard },
                presetCatalog: KeyboardPresetCatalog.bundled(),
                clock: ContinuousClock(),
                probeLimit: .seconds(2)
            )
        }
    }

    private struct PendingRead {
        let token = UUID()
        let row: ForeignSourceRow
        let importer: any ForeignAppImporter
        let request: ForeignImportRequest
    }

    @Published internal private(set) var step: SetupGuideStep = .origin
    @Published private var history: [SetupGuideStep] = []
    @Published internal var origin: SetupGuideOrigin = .newConnection {
        didSet { hasChosenOrigin = true }
    }
    @Published internal var recorded: SetupGuideFirstConnection?
    @Published internal private(set) var sources: [ForeignSourceRow] = []
    @Published internal private(set) var importPhase: SetupGuideImportPhase = .scanning
    @Published internal private(set) var ticked: Set<String> = []
    @Published internal private(set) var counting: Set<String> = []
    @Published private var choices: [String: ForeignImportRequest] = [:]
    @Published internal private(set) var results: [String: SetupGuideImportResult] = [:]
    @Published internal private(set) var importedIds: [UUID] = []
    @Published private var importOrigin: ImportOrigin = .ownMachineOrAccount
    @Published internal private(set) var shortcuts: SetupGuideShortcuts?
    internal private(set) var importedAppId: String?
    internal private(set) var isWaitingForProbe = false
    internal private(set) var hasScanned = false
    private var hasChosenOrigin = false
    internal var onEnd: ((SetupGuideEnding) -> Void)?

    private let dependencies: Dependencies
    private var hasEnded = false
    private var probeTask: Task<Void, Never>?
    private var probeDeadline: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var countTasks: [String: Task<Void, Never>] = [:]
    private var readTask: Task<Void, Never>?
    private var queue: [ForeignSourceRow] = []
    private var pending: PendingRead?

    internal init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    // MARK: - Navigation

    internal var canGoBack: Bool {
        !history.isEmpty && !isRunningImport
    }

    internal var isRunningImport: Bool {
        guard step == .import else { return false }
        switch importPhase {
        case .pickingFile, .notice, .reading, .review: return true
        case .scanning, .choosing: return false
        }
    }

    // An import started before a ticked source is counted would skip its Keychain notice.
    internal var canContinue: Bool {
        step != .import || counting.isEmpty
    }

    internal var ending: SetupGuideEnding {
        .resolve(recorded: recorded, importedIds: importedIds, origin: importOrigin)
    }

    internal var primaryTitle: String {
        switch step {
        case .origin, .firstConnection:
            String(localized: "Continue")
        case .import:
            importTitle
        case .options:
            String(localized: "Done")
        }
    }

    private var importTitle: String {
        guard case .choosing = importPhase, !ticked.isEmpty else { return String(localized: "Continue") }
        let count = tickedRows.reduce(0) { $0 + $1.inventory.connections }
        switch count {
        case 0: return String(localized: "Import")
        case 1: return String(localized: "Import 1 Connection")
        default: return String(format: String(localized: "Import %lld Connections"), count)
        }
    }

    // The probe picks the first step; an answer after its limit leaves the guide on origin.
    @discardableResult
    internal func start() -> Task<Void, Never> {
        if let probeTask { return probeTask }
        isWaitingForProbe = true
        let probe = dependencies.probe
        let task = Task { [weak self] in
            let found = await probe()
            self?.probeDidAnswer(found)
        }
        probeTask = task
        let clock = dependencies.clock
        let limit = dependencies.probeLimit
        probeDeadline = Task { [weak self] in
            do {
                try await clock.sleep(for: limit)
            } catch {
                return
            }
            self?.isWaitingForProbe = false
        }
        return task
    }

    private func probeDidAnswer(_ found: Set<String>) {
        probeDeadline?.cancel()
        probeDeadline = nil
        guard isWaitingForProbe else { return }
        isWaitingForProbe = false
        // A choice the user made on origin while the probe ran is theirs to keep.
        guard !found.isEmpty, !hasEnded, !hasChosenOrigin, step == .origin, history.isEmpty else { return }
        origin = .command(.otherApp)
        step = .import
        // Nobody has clicked yet, so this scan must raise no privacy prompt.
        beginScan(.unguarded)
    }

    internal func primary() {
        guard canContinue else { return }
        switch step {
        case .origin:
            continueFromOrigin()
        case .import:
            continueFromImport()
        case .firstConnection:
            go(to: .options)
        case .options:
            end(ending)
        }
    }

    internal func skip() {
        guard !isRunningImport else { return }
        end(ending)
    }

    internal func back() {
        guard canGoBack, let previous = history.popLast() else { return }
        // Origin's Continue recorded the choice; going back to it takes that back.
        if previous == .origin {
            recorded = nil
        }
        step = previous
    }

    // Closing the window ends the guide too, with no handoff.
    internal func stop() {
        hasEnded = true
        for task in [probeTask, probeDeadline, scanTask, readTask] {
            task?.cancel()
        }
        for task in countTasks.values {
            task.cancel()
        }
        probeDeadline = nil
        scanTask = nil
        countTasks = [:]
        readTask = nil
    }

    private func continueFromOrigin() {
        switch origin {
        case .command(.otherApp):
            recorded = nil
            go(to: .import)
        case .command(let command):
            end(.command(command))
        case .newConnection:
            recorded = .newConnection
            go(to: .options)
        case .sample:
            recorded = .sample
            go(to: .options)
        }
    }

    private func continueFromImport() {
        switch importPhase {
        case .choosing where !ticked.isEmpty:
            startImport()
        case .scanning, .choosing:
            go(to: .firstConnection)
        case .pickingFile, .notice, .reading, .review:
            return
        }
    }

    private func go(to next: SetupGuideStep) {
        history.append(step)
        step = next
        switch next {
        case .import: beginScan(.everything)
        case .options: prepareShortcuts()
        case .origin, .firstConnection: break
        }
    }

    private func end(_ ending: SetupGuideEnding) {
        guard !hasEnded else { return }
        stop()
        onEnd?(ending)
    }

    // MARK: - Sources

    internal var tickedRows: [ForeignSourceRow] {
        sources.filter { ticked.contains($0.id) }
    }

    internal func setTicked(_ isTicked: Bool, for row: ForeignSourceRow) {
        let current = sources.first { $0.id == row.id } ?? row
        guard current.availability == .available else { return }
        guard isTicked else {
            ticked.remove(current.id)
            return
        }
        ticked.insert(current.id)
        if !current.isCounted {
            countSource(current)
        }
    }

    internal func request(for row: ForeignSourceRow) -> ForeignImportRequest {
        let chosen = choices[row.id] ?? ForeignSourcePickerModel.defaultRequest(for: row)
        return ForeignImportRequest(
            includePasswords: chosen.includePasswords,
            includeSavedQueries: offersSavedQueries(row) && chosen.includeSavedQueries
        )
    }

    internal func offersSavedQueries(_ row: ForeignSourceRow) -> Bool {
        ForeignSourcePickerModel.offersSavedQueries(row.importer)
    }

    internal func setIncludePasswords(_ include: Bool, for row: ForeignSourceRow) {
        var request = request(for: row)
        request.includePasswords = include
        choices[row.id] = request
    }

    internal func setIncludeSavedQueries(_ include: Bool, for row: ForeignSourceRow) {
        var request = request(for: row)
        request.includeSavedQueries = include
        choices[row.id] = request
    }

    private func beginScan(_ reach: ForeignSourceScanReach) {
        guard !hasScanned, scanTask == nil else { return }
        importPhase = .scanning
        let scan = dependencies.scan
        scanTask = Task { [weak self] in
            let rows = await scan(reach)
            self?.scanDidFinish(rows)
        }
    }

    // Read only on the user's tick, so a privacy prompt it raises follows that click.
    private func countSource(_ row: ForeignSourceRow) {
        guard countTasks[row.id] == nil else { return }
        counting.insert(row.id)
        let counter = dependencies.count
        let importer = row.importer
        countTasks[row.id] = Task { [weak self] in
            let counted = await counter(importer)
            self?.countDidFinish(counted)
        }
    }

    private func countDidFinish(_ counted: ForeignSourceRow) {
        guard !hasEnded else { return }
        countTasks[counted.id] = nil
        counting.remove(counted.id)
        guard let index = sources.firstIndex(where: { $0.id == counted.id }) else { return }
        sources[index] = counted
        if counted.availability != .available {
            ticked.remove(counted.id)
        }
    }

    private func scanDidFinish(_ rows: [ForeignSourceRow]) {
        guard !hasEnded else { return }
        scanTask = nil
        hasScanned = true
        sources = rows
        ticked = Set(ForeignSourceRule.ticked(rows.map(\.summary)))
        importPhase = .choosing
        let found = rows.filter { $0.availability == .available && !$0.picksFile }.count
        dependencies.announce(Self.foundAnnouncement(found))
    }

    private static func foundAnnouncement(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No other database apps found.")
        case 1: String(localized: "1 app found.")
        default: String(format: String(localized: "%lld apps found."), count)
        }
    }

    // MARK: - Import queue

    // Ticked sources one at a time in list order; each read sees the library the previous apply left.
    private func startImport() {
        queue = tickedRows
        ticked.subtract(queue.map(\.id))
        nextInQueue()
    }

    private func nextInQueue() {
        pending = nil
        readTask = nil
        guard !queue.isEmpty else {
            importPhase = .choosing
            return
        }
        let row = queue.removeFirst()
        if row.picksFile {
            importPhase = .pickingFile(row)
            return
        }
        prepare(row, importer: row.importer)
    }

    internal func fileChosen(_ url: URL) {
        guard case .pickingFile(let row) = importPhase else { return }
        var importer = row.importer
        importer.setSelectedFile(url)
        prepare(row, importer: importer)
    }

    // A cancelled file panel, Keychain notice, read or review moves on to the next source.
    internal func skipCurrentSource() {
        readTask?.cancel()
        nextInQueue()
    }

    internal func confirmKeychainNotice() {
        guard case .notice = importPhase else { return }
        read()
    }

    internal func reviewFinished(_ outcome: ImportOutcome) {
        guard let pending, case .review = importPhase else { return }
        results[pending.row.id] = .imported(outcome)
        for id in outcome.connectionIds where !importedIds.contains(id) {
            importedIds.append(id)
        }
        if !outcome.connectionIds.isEmpty, pending.importer.importOrigin == .fileOrLink {
            importOrigin = .fileOrLink
        }
        if importedAppId == nil, !outcome.connectionIds.isEmpty {
            importedAppId = pending.row.id
        }
        dependencies.announce(ImportOutcomeMessage(outcome).message)
        nextInQueue()
    }

    private func prepare(_ row: ForeignSourceRow, importer: any ForeignAppImporter) {
        let request = request(for: row)
        pending = PendingRead(row: row, importer: importer, request: request)
        if let notice = KeychainNotice.needed(for: importer, request: request, inventory: row.inventory) {
            importPhase = .notice(notice)
            return
        }
        read()
    }

    private func read() {
        guard let pending else { return }
        importPhase = .reading(appName: pending.importer.displayName)
        let reader = dependencies.read
        readTask = Task { [weak self] in
            do {
                let collected = try await reader(pending.importer, pending.request)
                try Task.checkCancellation()
                self?.readDidFinish(collected, token: pending.token)
            } catch is CancellationError {
                return
            } catch {
                self?.readDidFail(error, token: pending.token)
            }
        }
    }

    private func readDidFinish(_ read: ForeignAppRead, token: UUID) {
        guard !hasEnded, pending?.token == token else { return }
        readTask = nil
        importPhase = .review(read, id: token)
    }

    private func readDidFail(_ error: any Error, token: UUID) {
        guard !hasEnded, let pending, pending.token == token else { return }
        let reason = ImportReviewLoader.message(for: error)
        results[pending.row.id] = .failed(reason)
        dependencies.announce(reason)
        nextInQueue()
    }

    // MARK: - Options

    // The shortcuts found on first arrival stay the ones Keep Current puts back; the listing follows later imports.
    private func prepareShortcuts() {
        let presets = dependencies.presetCatalog?.listing(first: importedAppId) ?? []
        guard var existing = shortcuts else {
            shortcuts = SetupGuideShortcuts(original: dependencies.keyboard(), presets: presets)
            return
        }
        existing.presets = presets
        shortcuts = existing
    }

    internal func selectShortcut(_ option: SetupGuideShortcuts.Option) {
        shortcuts?.select(option)
    }
}
