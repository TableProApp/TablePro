//
//  RowGenerationSession.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
internal protocol RowGenerationDataSource: AnyObject {
    var booleanStyle: RowGenerationBooleanStyle { get }
    var uniqueNullsAreDistinct: Bool { get }
    func loadTable() async throws -> RowGenerationTable
    func insert(
        engine: RowGenerationEngine,
        rowCount: Int,
        progress: @escaping @MainActor @Sendable (Int) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Int
    func insertScript(columns: [String], rows: [[PluginCellValue]]) throws -> String
}

// What a run that did not finish left in the table: a rolled back transaction keeps nothing.
internal struct RowGenerationWriteError: LocalizedError {
    internal let underlying: (any Error)?
    internal let keptRows: Int

    internal var isCancellation: Bool { underlying == nil }
    internal var errorDescription: String? { underlying?.localizedDescription }
}

internal enum RowGenerationOutcome: Equatable {
    case inserted(Int)
    case cancelled(keptRows: Int)
    case failed(message: String, keptRows: Int)
}

internal enum RowGenerationPhase: Equatable {
    case loading
    case loadFailed(String)
    case configuring
    case running
    case finished(RowGenerationOutcome)
}

internal struct RowGenerationPreview: Equatable {
    internal let columns: [String]
    internal let rows: [[PluginCellValue]]
}

@MainActor
internal final class RowGenerationSession: ObservableObject, Identifiable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RowGeneration")
    internal static let previewRowCount = 10
    internal static let scriptRowLimit = 10_000

    internal let id = UUID()
    internal let tableName: String
    internal let scopeDescription: String
    private let scope: TableScope
    private let dataSource: any RowGenerationDataSource
    private let store: RowGenerationSettingsStore
    private let calendar: Calendar
    private let now: () -> Date
    private let onOpenScript: (String) -> Void

    @Published internal private(set) var phase: RowGenerationPhase = .loading
    @Published internal private(set) var table: RowGenerationTable?
    @Published internal var settings: RowGenerationSettings
    @Published internal var selectedColumnName: String?
    @Published internal private(set) var writtenRows = 0
    @Published internal private(set) var targetRows = 0

    internal private(set) var runTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)

    internal init(
        tableName: String,
        scopeDescription: String,
        scope: TableScope,
        dataSource: any RowGenerationDataSource,
        store: RowGenerationSettingsStore = .shared,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init,
        onOpenScript: @escaping (String) -> Void
    ) {
        self.tableName = tableName
        self.scopeDescription = scopeDescription
        self.scope = scope
        self.dataSource = dataSource
        self.store = store
        self.calendar = calendar
        self.now = now
        self.onOpenScript = onOpenScript
        settings = RowGenerationSettings(seed: Self.randomSeed(), columns: [:])
    }

    internal static func randomSeed() -> UInt64 {
        UInt64.random(in: 1...999_999)
    }

    // MARK: - Loading

    // The sheet's `.task` restarts whenever the sheet is shown again, so a load in flight is joined, not repeated.
    internal func loadIfNeeded() async {
        guard table == nil else { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func load() async {
        phase = .loading
        do {
            let loaded = try await dataSource.loadTable()
            table = loaded
            settings = resolvedSettings(for: loaded, saved: store.settings(for: scope))
            selectedColumnName = loaded.columns.first?.name
            phase = .configuring
        } catch {
            Self.logger.warning("Generate Rows could not read the table: \(error.publicLogShape, privacy: .public)")
            phase = .loadFailed(error.localizedDescription)
        }
    }

    // A saved generator that no longer fits the column, because its type changed, gives way to the default.
    private func resolvedSettings(for table: RowGenerationTable, saved: RowGenerationSettings?) -> RowGenerationSettings {
        var columns: [String: RowGeneratorSettings] = [:]
        for column in table.columns {
            let fresh = RowGenerationDefaults.settings(for: column, in: table, now: now(), calendar: calendar)
            guard var kept = saved?.columns[column.name], column.availableKinds.contains(kept.kind) else {
                columns[column.name] = fresh
                continue
            }
            // A key column's sequence moves past the rows already there, so a second run does not collide.
            if column.isUnique, kept.kind == .sequence, kept.sequenceStep > 0 {
                kept.integerMinimum = max(kept.integerMinimum, fresh.integerMinimum)
            }
            columns[column.name] = kept
        }
        return RowGenerationSettings(
            rowCount: saved?.rowCount ?? RowGenerationSettings.defaultRowCount,
            seed: saved?.seed ?? settings.seed,
            columns: columns
        )
    }

    // MARK: - Editing

    internal func columnSettings(_ name: String) -> RowGeneratorSettings? {
        settings.columns[name]
    }

    internal func updateColumn(_ name: String, _ change: (inout RowGeneratorSettings) -> Void) {
        guard var current = settings.columns[name] else { return }
        change(&current)
        settings.columns[name] = current
    }

    internal func shuffleSeed() {
        settings.seed = Self.randomSeed()
    }

    internal var selectedColumn: RowGenerationColumn? {
        guard let selectedColumnName else { return nil }
        return table?.column(named: selectedColumnName)
    }

    // MARK: - Checks

    internal var issues: [RowGenerationIssue] {
        guard let table else { return [] }
        return RowGenerationValidation.issues(for: settings, in: table, calendar: calendar)
    }

    internal func issues(for column: String) -> [RowGenerationIssue] {
        issues.filter { $0.column == column }
    }

    internal var canGenerate: Bool {
        phase == .configuring && issues.isEmpty
    }

    internal var canOpenScript: Bool {
        canGenerate && settings.rowCount <= Self.scriptRowLimit
    }

    internal var preview: Result<RowGenerationPreview, Error>? {
        guard let table, issues.isEmpty else { return nil }
        let engine = makeEngine(for: table)
        do {
            let rows = try engine.nextRows(min(Self.previewRowCount, settings.rowCount))
            return .success(RowGenerationPreview(columns: engine.columnNames, rows: rows))
        } catch {
            return .failure(error)
        }
    }

    private func makeEngine(for table: RowGenerationTable) -> RowGenerationEngine {
        RowGenerationEngine(
            table: table,
            settings: settings,
            booleanStyle: dataSource.booleanStyle,
            nullsAreDistinct: dataSource.uniqueNullsAreDistinct,
            calendar: calendar
        )
    }

    // MARK: - Running

    internal func start() {
        guard canGenerate, let table else { return }
        store.save(settings, for: scope)
        let engine = makeEngine(for: table)
        let count = settings.rowCount
        cancelFlag.withLock { $0 = false }
        writtenRows = 0
        targetRows = count
        phase = .running
        let flag = cancelFlag
        runTask = Task { [weak self] in
            guard let self else { return }
            let outcome: RowGenerationOutcome
            do {
                let inserted = try await dataSource.insert(
                    engine: engine,
                    rowCount: count,
                    progress: { [weak self] written in self?.writtenRows = written },
                    isCancelled: { flag.withLock { $0 } }
                )
                outcome = .inserted(inserted)
            } catch ExecutionGateError.cancelledByUser {
                phase = .configuring
                return
            } catch let failure as RowGenerationWriteError {
                outcome = failure.isCancellation
                    ? .cancelled(keptRows: failure.keptRows)
                    : .failed(message: failure.errorDescription ?? "", keptRows: failure.keptRows)
            } catch {
                outcome = .failed(message: error.localizedDescription, keptRows: 0)
            }
            advanceKeySequences(past: outcome)
            phase = .finished(outcome)
        }
    }

    // Rows that stayed hold the sequence's first values, so a second run from Edit Settings starts after them.
    private func advanceKeySequences(past outcome: RowGenerationOutcome) {
        let kept: Int
        switch outcome {
        case .inserted(let count): kept = count
        case .cancelled(let count), .failed(_, let count): kept = count
        }
        guard kept > 0, let table else { return }
        for column in table.columns where column.isUnique {
            updateColumn(column.name) { settings in
                guard settings.kind == .sequence, settings.sequenceStep > 0 else { return }
                let advance = settings.sequenceStep.multipliedReportingOverflow(by: Int64(kept))
                let next = settings.integerMinimum.addingReportingOverflow(advance.partialValue)
                guard !advance.overflow, !next.overflow else { return }
                settings.integerMinimum = next.partialValue
            }
        }
    }

    internal func cancel() {
        cancelFlag.withLock { $0 = true }
    }

    internal func editSettings() {
        guard case .finished = phase else { return }
        phase = .configuring
    }

    internal var progressFraction: Double {
        guard targetRows > 0 else { return 0 }
        return min(1, Double(writtenRows) / Double(targetRows))
    }

    internal func openScript() throws {
        guard canOpenScript, let table else { return }
        store.save(settings, for: scope)
        let engine = makeEngine(for: table)
        let rows = try engine.nextRows(settings.rowCount)
        onOpenScript(try dataSource.insertScript(columns: engine.columnNames, rows: rows))
    }
}
