import Combine
import Foundation
import os
import SwiftUI
import TableProImport

@MainActor
internal final class ImportReview: ObservableObject {
    let preview: ImportPreview
    @Published private(set) var selection: ImportSelection {
        didSet { cachedPlan = nil }
    }
    @Published private(set) var isImporting = false

    private var cachedPlan: ImportPlan?
    private let sqlByRef: [BundleRef: String]
    private let library: any ImportLibraryStore
    private let savedQueryStore: (any SavedQueryImportStore)?

    init(
        preview: ImportPreview,
        library: any ImportLibraryStore = MacImportLibraryStore(),
        savedQueries: (any SavedQueryImportStore)? = SQLFavoriteManager.shared
    ) {
        self.preview = preview
        self.sqlByRef = Dictionary(
            preview.collected.bundle.savedQueries.map { ($0.ref, $0.sql) },
            uniquingKeysWith: { first, _ in first }
        )
        self.library = library
        self.savedQueryStore = savedQueries
        self.selection = ImportSelection.defaults(for: preview)
    }

    /// Planned on first read after a change, so a header toggle that flips every row plans once.
    var plan: ImportPlan {
        if let cachedPlan { return cachedPlan }
        let planned = ImportPlanner.plan(preview, selection: selection)
        cachedPlan = planned
        return planned
    }

    func isSelected(_ row: ConnectionRow) -> Bool {
        selection.resolution(for: row.ref) != nil
    }

    func setSelected(_ selected: Bool, _ row: ConnectionRow) {
        selection.setSelected(selected, connection: row.ref, in: preview)
    }

    func resolution(for row: ConnectionRow) -> ConnectionResolution {
        selection.resolution(for: row.ref) ?? row.resolutions.first ?? .add
    }

    func setResolution(_ resolution: ConnectionResolution, for row: ConnectionRow) {
        selection.resolve(row.ref, as: resolution, in: preview)
    }

    func offeredResolutions(for row: ConnectionRow) -> [ConnectionResolution] {
        selection.offeredResolutions(for: row)
    }

    func status(of row: QueryRow) -> QueryStatus? {
        plan.queryStatuses[row.ref]
    }

    func sqlPreview(of row: QueryRow) -> String? {
        guard let sql = sqlByRef[row.ref] else { return nil }
        let text = sql as NSString
        return text.length > Self.sqlPreviewLength ? text.substring(to: Self.sqlPreviewLength) + "…" : sql
    }

    private static let sqlPreviewLength = 1_000

    func setIncluded(_ included: Bool, _ row: QueryRow) {
        selection.setIncluded(included, query: row.ref)
    }

    var connectionToggles: [Binding<Bool>] {
        preview.connections.map { row in
            Binding(
                get: { [weak self] in self?.isSelected(row) ?? false },
                set: { [weak self] in self?.setSelected($0, row) }
            )
        }
    }

    /// Rows another selected row already adds stay in the header's set, so unchecking it reaches them too.
    var queryToggles: [Binding<Bool>] {
        preview.queries
            .filter { [.available, .addedByAnotherRow].contains(status(of: $0)?.availability) }
            .map { row in
                Binding(
                    get: { [weak self] in self?.selection.wantsQuery(row) ?? false },
                    set: { [weak self] in self?.setIncluded($0, row) }
                )
            }
    }

    var selectedConnectionCount: Int {
        preview.connections.count(where: { isSelected($0) })
    }

    var includedQueryCount: Int {
        plan.queryStatuses.values.count(where: \.isIncluded)
    }

    /// Keep Existing writes no settings, so its commands never reach this Mac.
    var rowsWithCommands: [ConnectionRow] {
        preview.connections.filter { row in
            guard row.carriesCommands, let resolution = selection.resolution(for: row.ref) else { return false }
            if case .keepExisting = resolution { return false }
            return true
        }
    }

    func commit(keepingCommands: Bool) async -> ImportOutcome {
        selection.keepsCommands = keepingCommands
        isImporting = true
        defer { isImporting = false }
        let savedQueries = preview.environment.rules.supportsSavedQueries ? savedQueryStore : nil
        return await ImportApplier.apply(plan, library: library, savedQueries: savedQueries)
    }
}

@MainActor
internal enum ImportReviewLoader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportReview")

    static func preview(
        of collected: CollectedImport,
        store: MacImportLibraryStore = MacImportLibraryStore()
    ) async throws -> ImportPreview {
        let inputs: (library: ImportLibrarySnapshot, environment: ImportEnvironment)
        do {
            inputs = try await store.analysisInputs(environment: MacImportEnvironment.make())
        } catch {
            logger.error("Import preview could not read the library: \(error.publicLogShape, privacy: .public)")
            throw error
        }
        return await analyze(collected, library: inputs.library, environment: inputs.environment)
    }

    static func message(for error: any Error) -> String {
        if error is ImportStoreError {
            return String(localized: "TablePro could not read your connection library, so nothing was imported.")
        }
        return error.localizedDescription
    }

    @concurrent
    nonisolated private static func analyze(
        _ collected: CollectedImport,
        library: ImportLibrarySnapshot,
        environment: ImportEnvironment
    ) async -> ImportPreview {
        ConnectionImportAnalyzer.analyze(collected, library: library, environment: environment)
    }
}
