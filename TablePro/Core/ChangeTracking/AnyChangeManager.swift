//
//  AnyChangeManager.swift
//  TablePro
//
//  Type-erased wrapper for change managers (data and structure).
//  Allows DataGridView to work with both DataChangeManager and StructureChangeManager.
//

import Foundation
import Observation

/// Type-erased change manager wrapper
@Observable
@MainActor
final class AnyChangeManager {
    @ObservationIgnored private(set) var dataManager: DataChangeManager?
    @ObservationIgnored private(set) var structureManager: StructureChangeManager?

    var hasChanges: Bool {
        dataManager?.hasChanges ?? structureManager?.hasChanges ?? false
    }

    var reloadVersion: Int {
        dataManager?.reloadVersion ?? structureManager?.reloadVersion ?? 0
    }

    @ObservationIgnored private let _isRowDeleted: (Int) -> Bool
    @ObservationIgnored private let _getChanges: () -> [Any]
    @ObservationIgnored private let _canRedo: () -> Bool
    @ObservationIgnored private let _recordCellChange: ((Int, Int, String, String?, String?, [String?]) -> Void)?
    @ObservationIgnored private let _undoRowDeletion: ((Int) -> Void)?
    @ObservationIgnored private let _undoRowInsertion: ((Int) -> Void)?
    @ObservationIgnored private let _consumeChangedRowIndices: (() -> Set<Int>)?

    // MARK: - Initializers

    /// Wrap a DataChangeManager
    init(dataManager: DataChangeManager) {
        self.dataManager = dataManager
        self._isRowDeleted = { rowIndex in
            dataManager.isRowDeleted(rowIndex)
        }
        self._getChanges = {
            dataManager.changes
        }
        self._canRedo = {
            dataManager.undoManager.canRedo
        }
        self._recordCellChange = { rowIndex, columnIndex, columnName, oldValue, newValue, originalRow in
            dataManager.recordCellChange(
                rowIndex: rowIndex,
                columnIndex: columnIndex,
                columnName: columnName,
                oldValue: oldValue,
                newValue: newValue,
                originalRow: originalRow
            )
        }
        self._undoRowDeletion = { rowIndex in
            dataManager.undoRowDeletion(rowIndex: rowIndex)
        }
        self._undoRowInsertion = { rowIndex in
            dataManager.undoRowInsertion(rowIndex: rowIndex)
        }
        self._consumeChangedRowIndices = {
            dataManager.consumeChangedRowIndices()
        }
    }

    /// Wrap a StructureChangeManager
    init(structureManager: StructureChangeManager) {
        self.structureManager = structureManager
        self._isRowDeleted = { _ in false } // Structure doesn't track row deletions
        self._getChanges = {
            Array(structureManager.pendingChanges.values)
        }
        self._canRedo = {
            structureManager.undoManager.canRedo
        }
        self._recordCellChange = nil // Structure uses custom editing logic
        self._undoRowDeletion = nil
        self._undoRowInsertion = nil
        self._consumeChangedRowIndices = {
            structureManager.consumeChangedRowIndices()
        }
    }

    // MARK: - Public API

    var undoManager: UndoManager? {
        if let dataManager { return dataManager.undoManager }
        if let structureManager { return structureManager.undoManager }
        return nil
    }

    var canRedo: Bool {
        _canRedo()
    }

    func isRowDeleted(_ rowIndex: Int) -> Bool {
        _isRowDeleted(rowIndex)
    }

    var changes: [Any] {
        _getChanges()
    }

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: String?,
        newValue: String?,
        originalRow: [String?]
    ) {
        _recordCellChange?(rowIndex, columnIndex, columnName, oldValue, newValue, originalRow)
    }

    func undoRowDeletion(rowIndex: Int) {
        _undoRowDeletion?(rowIndex)
    }

    func undoRowInsertion(rowIndex: Int) {
        _undoRowInsertion?(rowIndex)
    }

    func consumeChangedRowIndices() -> Set<Int> {
        _consumeChangedRowIndices?() ?? []
    }
}
