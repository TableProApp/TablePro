//
//  CompareSyncSession.swift
//  TablePro
//
//  Drives the compare and sync flow. Owns no cache: every comparison is a fresh
//  read that replaces the previous result only once it has finished, so a re-run
//  never blanks what is on screen before it has something to show.
//

import Foundation
import Observation
import os
import SwiftUI
import TableProPluginKit

internal enum CompareSyncStep: Int, CaseIterable, Comparable {
    case setup
    case review
    case script
    case apply

    internal static func < (lhs: CompareSyncStep, rhs: CompareSyncStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    internal var title: String {
        switch self {
        case .setup: return String(localized: "Setup")
        case .review: return String(localized: "Review")
        case .script: return String(localized: "Script")
        case .apply: return String(localized: "Apply")
        }
    }
}

internal enum CompareSyncActivity: Equatable {
    case idle
    case connecting
    case comparing
    case applying
}

internal enum CompareSyncLastAction: Equatable {
    case none
    case compared(Date, differences: Int)
    case applied(Date, target: String, statements: Int)
}

@MainActor
@Observable
internal final class CompareSyncSession {
    private static let logger = Logger(subsystem: "com.TablePro", category: "CompareSyncSession")

    internal var step: CompareSyncStep = .setup
    internal var mode: CompareSyncMode = .structure
    internal var source: CompareSyncEndpoint?
    internal var target: CompareSyncEndpoint?
    internal var structureOptions = StructureCompareOptions.default
    internal var dataOptions = DataCompareOptions.default
    internal var executionSettings = CompareSyncExecutionSettings()

    internal var activity: CompareSyncActivity = .idle
    internal var errorMessage: String?
    internal var informationalMessage: String?
    internal var lastAction: CompareSyncLastAction = .none

    internal var structureReport: StructureDiffReport?
    internal var dataPlans: [DataComparePlan] = []
    internal var tableActions: [String: TableSyncAction] = [:]
    internal var statements: [SyncStatement] = []
    internal var editedScript: String?
    internal var runResult: CompareSyncRunResult?
    internal var progress: Progress?

    internal var hasWrittenToTarget = false
    internal var sourceSnapshotCache: [String: TableStructureSnapshot] = [:]
    internal var targetSnapshotCache: [String: TableStructureSnapshot] = [:]
    internal var pendingSelectedTables: Set<String> = []

    internal var runTask: Task<Void, Never>?

    internal init() {}

    // MARK: - Direction

    internal var directionSentence: String? {
        guard let source, let target else { return nil }
        return String(
            format: String(localized: "Compare %@ and write changes to %@."),
            source.qualifiedDescription, target.qualifiedDescription
        )
    }

    internal var canSwap: Bool {
        source != nil || target != nil
    }

    internal func swapEndpoints() {
        let previousSource = source
        source = target
        target = previousSource
        resetComparison()
    }

    internal var canCompare: Bool {
        guard let source, let target else { return false }
        guard target.canBeWrittenTo else { return false }
        return source.id != target.id && activity == .idle
    }

    internal var canGenerateStructureScript: Bool {
        guard mode == .structure, let source, let target else { return false }
        return CompareSyncEngineFamily.canGenerateStructureScript(from: source.databaseType, to: target.databaseType)
    }

    internal var crossEngineNotice: String? {
        guard let source, let target else { return nil }
        if mode == .structure, !canGenerateStructureScript {
            return CompareSyncEngineFamily.structureScriptRefusal(from: source.databaseType, to: target.databaseType)
        }
        return CompareSyncEngineFamily.crossEngineDataWarning(from: source.databaseType, to: target.databaseType)
    }

    internal var bannerText: String {
        switch activity {
        case .applying:
            return String(
                format: String(localized: "Applying to %@..."),
                target?.qualifiedDescription ?? ""
            )
        case .comparing, .connecting:
            return String(localized: "Comparing only. Nothing has been written.")
        case .idle:
            return idleBannerText
        }
    }

    private var idleBannerText: String {
        switch lastAction {
        case .none:
            return String(localized: "Comparing only. Nothing has been written.")
        case .compared(let date, let differences):
            return String(
                format: String(localized: "Compared %@. %d differences. Nothing has been written."),
                Self.timeFormatter.string(from: date), differences
            )
        case .applied(let date, let name, let statements):
            return String(
                format: String(localized: "Applied to %@ at %@. %d statements."),
                name, Self.timeFormatter.string(from: date), statements
            )
        }
    }

    // MARK: - Selection

    internal func action(for result: TableDiffResult) -> TableSyncAction {
        tableActions[result.id] ?? .skip
    }

    internal func setAction(_ action: TableSyncAction, for result: TableDiffResult) {
        tableActions[result.id] = action
        statements = []
        editedScript = nil
    }

    internal var selectedTableCount: Int {
        switch mode {
        case .structure:
            return tableActions.values.filter { $0 != .skip }.count
        case .data:
            return dataPlans.filter { $0.isEnabled && $0.isComparable && ($0.summary?.differenceCount ?? 0) > 0 }.count
        }
    }

    internal func runComparison() {
        switch mode {
        case .structure: compare()
        case .data: compareData()
        }
    }

    internal func buildScript() {
        switch mode {
        case .structure: generateScript()
        case .data: generateDataScript()
        }
    }

    internal var canBuildScript: Bool {
        switch mode {
        case .structure:
            return selectedTableCount > 0 && canGenerateStructureScript
        case .data:
            return selectedTableCount > 0
        }
    }

    internal func resetComparison() {
        structureReport = nil
        sourceSnapshotCache = [:]
        targetSnapshotCache = [:]
        dataPlans = []
        tableActions = [:]
        statements = []
        editedScript = nil
        runResult = nil
        errorMessage = nil
        step = .setup
    }

    // MARK: - Lifecycle

    internal func cancelRunningWork() {
        progress?.cancel()
        runTask?.cancel()
    }

    internal var isBusy: Bool {
        activity != .idle
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
