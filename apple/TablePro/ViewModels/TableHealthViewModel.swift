import Combine
import Foundation
import os

enum TableHealthScope: Hashable, Sendable {
    case all
    case check(TableHealthCheckKind)
    case resolved
}

enum TableHealthListState: Equatable {
    case rows
    case noFindings(String)
    case skipped(String)
    case failed(String)
    case noResults
    case ignoredHidden(Int)
    case noResolved
}

@MainActor
final class TableHealthViewModel: ObservableObject {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "TableHealth")
    private static let exportScopeAll = "all"
    private static let exportScopeShown = "shown"
    private static let exportScopeSelected = "selected"

    let provider: (any TableHealthProvider)?
    let connectionId: UUID

    @Published private(set) var report: TableHealthReport?
    @Published private(set) var ledger = TableHealthLedger()
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var loadError: String?
    @Published private(set) var storeError: String?

    @Published var scope: TableHealthScope = .all {
        didSet { if scope != oldValue { rebuildRows() } }
    }
    @Published var selection: Set<TableHealthFindingID> = []
    @Published var sortOrder: [KeyPathComparator<TableHealthFindingRow>] = [KeyPathComparator(\TableHealthFindingRow.checkOrder)] {
        didSet { rebuildRows() }
    }
    @Published var resolvedSortOrder: [KeyPathComparator<TableHealthFindingRow>] = [
        KeyPathComparator(\TableHealthFindingRow.lastSeenSortKey, order: .reverse)
    ] {
        didSet { rebuildRows() }
    }
    @Published var filterText = "" {
        didSet { if filterText != oldValue { rebuildRows() } }
    }
    @Published var showIgnored = false {
        didSet { if showIgnored != oldValue { rebuildRows() } }
    }

    // What the table shows for the scope, sorted and filtered once per change rather than in `body`.
    @Published private(set) var rows: [TableHealthFindingRow] = []
    // Every current finding, ignored ones included, in the current sort.
    @Published private(set) var findingRows: [TableHealthFindingRow] = []
    @Published private(set) var checkCounts: [TableHealthCheckKind: Int] = [:]
    @Published private(set) var allFindingsCount = 0
    @Published private(set) var resolvedCount = 0
    @Published private(set) var hiddenIgnoredCount = 0
    @Published private(set) var scopeRowCount = 0

    private let history: any TableHealthHistoryStoring
    private let metadata: any ScopedMetadataProviding
    // Read at each refresh, so a database rename retargets the next run and nothing follows the sidebar.
    private let database: @MainActor () -> String
    private var runTask: Task<Void, Never>?
    private var refreshQueued = false
    private var ledgerLoaded = false
    private var historyObserver: AnyCancellable?

    var isSupported: Bool { provider != nil }

    var databaseName: String { database() }

    init(
        connectionId: UUID,
        provider: (any TableHealthProvider)?,
        history: any TableHealthHistoryStoring,
        metadata: any ScopedMetadataProviding = DatabaseManager.shared,
        database: @escaping @MainActor () -> String
    ) {
        self.connectionId = connectionId
        self.provider = provider
        self.history = history
        self.metadata = metadata
        self.database = database
        historyObserver = NotificationCenter.default.publisher(for: .tableHealthHistoryDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.historyDidChange(notification)
            }
    }

    // MARK: - Loading

    // A pane switch restarts `.task`, so only the first appearance loads, and it joins a run already going.
    func loadIfNeeded() async {
        if !ledgerLoaded { reloadLedger() }
        guard report == nil, loadError == nil else { return }
        if let runTask {
            await runTask.value
            return
        }
        await refresh()
    }

    // The model owns the run, so a pane switch that cancels `.task` does not drop it. A refresh asked for during a run
    // runs once more after it: the first may have read the catalog before the change the user refreshed for.
    func refresh() async {
        if let runTask {
            refreshQueued = true
            await runTask.value
            return
        }
        guard let provider else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await runRefreshes(provider)
        }
        runTask = task
        await task.value
    }

    // The tab closed: stop reading so the bulk metadata lane is free for the next caller.
    func cancel() {
        refreshQueued = false
        runTask?.cancel()
    }

    private func runRefreshes(_ provider: any TableHealthProvider) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            runTask = nil
        }
        repeat {
            refreshQueued = false
            await performRefresh(provider)
        } while refreshQueued && !Task.isCancelled
    }

    private func performRefresh(_ provider: any TableHealthProvider) async {
        let target = self.database()
        do {
            let scope = DatabaseScope(connectionId: connectionId, database: target, schema: nil)
            let fresh = try await TableHealthReportLoader.load(provider: provider, scope: scope, metadata: metadata)
            guard !Task.isCancelled else { return }
            report = Self.merging(fresh, over: report)
            loadError = nil
            lastRefreshDate = Date()
            record(fresh, database: target)
            settleAfterRefresh()
            rebuildRows()
        } catch {
            if Task.isCancelled || error is CancellationError { return }
            Self.logger.warning("Table health refresh failed: \(error.publicLogShape, privacy: .public)")
            loadError = error.localizedDescription
        }
    }

    // A check that failed this time keeps the findings it had, shown under its new error.
    static func merging(_ fresh: TableHealthReport, over previous: TableHealthReport?) -> TableHealthReport {
        guard let previous, previous.database == fresh.database else { return fresh }
        var merged = fresh
        for index in merged.checks.indices {
            guard case .failed = merged.checks[index].outcome,
                  let prior = previous.checks.first(where: { $0.kind == merged.checks[index].kind })
            else { continue }
            merged.checks[index].findings = prior.findings
        }
        return merged
    }

    private func settleAfterRefresh() {
        if case .check(let kind) = scope, report?.result(for: kind) == nil {
            scope = .all
        }
        var known = Set(report?.findings.map(\.id) ?? [])
        known.formUnion(ledger.resolved.map(\.id))
        let kept = selection.intersection(known)
        if kept != selection { selection = kept }
    }

    // MARK: - History

    private func record(_ report: TableHealthReport, database: String) {
        do {
            ledger = try history.record(report, connectionId: connectionId, database: database, at: report.generatedAt)
            ledgerLoaded = true
            storeError = nil
        } catch {
            Self.logger.error("Table health history not recorded: \(error.publicLogShape, privacy: .public)")
            storeError = error.localizedDescription
        }
    }

    private func reloadLedger() {
        let target = self.database()
        guard !target.isEmpty else { return }
        do {
            let fresh = try history.ledger(connectionId: connectionId, database: target)
            ledgerLoaded = true
            guard fresh != ledger else { return }
            ledger = fresh
            rebuildRows()
        } catch {
            Self.logger.error("Table health history not read: \(error.publicLogShape, privacy: .public)")
            storeError = error.localizedDescription
        }
    }

    private func historyDidChange(_ notification: Notification) {
        guard let changed = TableHealthHistoryChange.scope(of: notification),
              changed.connectionId == connectionId,
              changed.database == database()
        else { return }
        reloadLedger()
    }

    func setIgnored(_ ids: Set<TableHealthFindingID>, ignored: Bool) {
        guard !ids.isEmpty else { return }
        updateLedger {
            try history.setIgnored(ids, ignored: ignored, connectionId: connectionId, database: database(), at: Date())
        }
    }

    func clearResolved() {
        updateLedger {
            try history.clearResolved(connectionId: connectionId, database: database())
        }
    }

    private func updateLedger(_ change: () throws -> TableHealthLedger) {
        guard !database().isEmpty else { return }
        do {
            ledger = try change()
            ledgerLoaded = true
            storeError = nil
        } catch {
            Self.logger.error("Table health history not saved: \(error.publicLogShape, privacy: .public)")
            storeError = error.localizedDescription
        }
        rebuildRows()
    }

    // MARK: - Rows

    private func rebuildRows() {
        var current: [TableHealthFindingRow] = []
        var checkPositions: [TableHealthCheckKind: (title: String, order: Int)] = [:]
        for (order, result) in (report?.checks ?? []).enumerated() {
            checkPositions[result.kind] = (result.check.title, order)
            for finding in result.findings {
                current.append(TableHealthFindingRow(
                    finding: finding,
                    checkTitle: result.check.title,
                    checkOrder: order,
                    status: rowStatus(of: finding.id),
                    firstSeen: ledger.firstSeen(finding.id),
                    lastSeen: ledger.lastSeen(finding.id)
                ))
            }
        }
        findingRows = current.sorted(using: sortOrder)

        let visible = findingRows.filter { showIgnored || $0.status != .ignored }
        var counts: [TableHealthCheckKind: Int] = [:]
        for row in visible {
            counts[row.id.kind, default: 0] += 1
        }
        checkCounts = counts
        allFindingsCount = visible.count

        let checkCount = checkPositions.count
        let resolved = ledger.resolved.map { entry -> TableHealthFindingRow in
            let kind = entry.id.kind
            let position = checkPositions[kind]
                ?? (title: kind.title, order: checkCount + (TableHealthCheckKind.allCases.firstIndex(of: kind) ?? 0))
            return TableHealthFindingRow(resolved: entry, checkTitle: position.title, checkOrder: position.order)
        }
        resolvedCount = resolved.count

        let inScope: [TableHealthFindingRow]
        switch scope {
        case .all:
            inScope = visible
            hiddenIgnoredCount = findingRows.count - visible.count
        case .check(let kind):
            inScope = visible.filter { $0.id.kind == kind }
            hiddenIgnoredCount = showIgnored ? 0 : findingRows.filter { $0.id.kind == kind && $0.status == .ignored }.count
        case .resolved:
            inScope = resolved.sorted(using: resolvedSortOrder)
            hiddenIgnoredCount = 0
        }
        scopeRowCount = inScope.count

        let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        rows = filter.isEmpty ? inScope : inScope.filter { $0.matches(filter) }
    }

    private func rowStatus(of id: TableHealthFindingID) -> TableHealthRowStatus {
        switch ledger.status(of: id) {
        case .new: return .new
        case .ignored: return .ignored
        case .none: return .seen
        }
    }

    func badgeCount(for kind: TableHealthCheckKind) -> Int {
        checkCounts[kind] ?? 0
    }

    // The selection as the table shows it: a row the filter or the scope hides is not acted on.
    var selectedRows: [TableHealthFindingRow] {
        rows.filter { selection.contains($0.id) }
    }

    var selectedFindings: [TableHealthFinding] {
        selectedRows.compactMap(\.finding)
    }

    var shownFindings: [TableHealthFinding] {
        rows.compactMap(\.finding)
    }

    func rows(for ids: Set<TableHealthFindingID>) -> [TableHealthFindingRow] {
        rows.filter { ids.contains($0.id) }
    }

    var hasExportableRows: Bool {
        !findingRows.isEmpty || !rows.isEmpty
    }

    var currentCheck: TableHealthCheckResult? {
        guard case .check(let kind) = scope else { return nil }
        return report?.result(for: kind)
    }

    // A check that failed but kept its earlier findings shows them under this line.
    var checkFailure: String? {
        guard let currentCheck, case .failed(let message) = currentCheck.outcome, !currentCheck.findings.isEmpty
        else { return nil }
        return message
    }

    var notes: [String] {
        switch scope {
        case .all:
            return report?.notes ?? []
        case .check:
            return (report?.notes ?? []) + [currentCheck?.note].compactMap { $0 }
        case .resolved:
            return []
        }
    }

    var listState: TableHealthListState {
        if !rows.isEmpty { return .rows }
        if let currentCheck {
            switch currentCheck.outcome {
            case .skipped(let reason):
                return .skipped(reason)
            case .failed(let message) where currentCheck.findings.isEmpty:
                return .failed(message)
            case .failed, .completed:
                break
            }
        }
        if !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scopeRowCount > 0 {
            return .noResults
        }
        if hiddenIgnoredCount > 0 { return .ignoredHidden(hiddenIgnoredCount) }
        switch scope {
        case .all:
            return .noFindings(String(localized: "Every check that ran found nothing."))
        case .check:
            return .noFindings(currentCheck?.check.summary ?? "")
        case .resolved:
            return .noResolved
        }
    }

    // MARK: - Fixes

    nonisolated static func hasFix(_ finding: TableHealthFinding) -> Bool {
        guard let fix = finding.fixSQL else { return false }
        return !fix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Every fix in one script, each under a comment naming its finding: what Save Fix Script writes.
    func fixScript(for findings: [TableHealthFinding], databaseType: DatabaseType) -> String? {
        let fixes = findings.filter(Self.hasFix)
        guard !fixes.isEmpty, let report else { return nil }
        return TableHealthFixScript.script(
            database: report.database,
            generatedAt: report.generatedAt,
            databaseType: databaseType,
            findings: fixes,
            checkTitle: { report.result(for: $0)?.check.title ?? $0.title }
        )
    }

    // One fix as it is; several as the script, so the preview, Copy and Open in Editor show the same text.
    func fixText(for findings: [TableHealthFinding], databaseType: DatabaseType) -> String? {
        let fixes = findings.filter(Self.hasFix)
        if fixes.count == 1 { return fixes[0].fixSQL }
        return fixScript(for: fixes, databaseType: databaseType)
    }

    // MARK: - Copy and export

    func tsv(for rows: [TableHealthFindingRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        return TableHealthTSV.text(rows, columns: scope == .resolved ? TableHealthColumn.resolved : TableHealthColumn.findings)
    }

    // A snapshot: a refresh while the dialog is open does not change what it writes or the counts it shows.
    func exportRequest() -> DataSourceExportRequest? {
        guard hasExportableRows else { return nil }
        let exportDatabase = report?.database ?? databaseName
        let makeScope: (String, String, [TableHealthFindingRow]) -> DataSourceExportScope = { id, title, rows in
            DataSourceExportScope(id: id, title: String(format: title, rows.count.formatted()), rowCount: rows.count) {
                TableHealthExportDataSource(database: exportDatabase, rows: rows)
            }
        }
        var scopes = [makeScope(Self.exportScopeAll, String(localized: "All Findings (%@)"), findingRows)]
        let showsSubset = scope != .all
            || !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hiddenIgnoredCount > 0
        if showsSubset {
            scopes.append(makeScope(Self.exportScopeShown, String(localized: "Shown Findings (%@)"), rows))
        }
        let selected = selectedRows
        if !selected.isEmpty {
            scopes.append(makeScope(Self.exportScopeSelected, String(localized: "Selected Findings (%@)"), selected))
        }
        let title = String(format: String(localized: "Table Health for %@"), exportDatabase)
        return DataSourceExportRequest(
            title: title,
            suggestedFileName: title,
            scopes: scopes,
            initialScopeId: showsSubset ? Self.exportScopeShown : Self.exportScopeAll
        )
    }
}
