//
//  DataGridViewController+ValueEditor.swift
//  TablePro
//

import AppKit
import TableProPluginKit

extension DataGridViewController {
    func valueEditor(for cell: DataGridEditCell) -> DataGridValueEditor? {
        let isWritable = model.isColumnWritable(cell.column) && !isRowDeleted(cell.row.id)
        // A locked column reads here, where it beeps under Return: this command never types into the cell.
        let mode = CellInteractionResolver().resolve(cellContext(for: cell, locksAsReadOnly: true))
        return DataGridValueEditor.resolve(
            mode: mode,
            chevron: isWritable ? chevronEditor(for: cell) : nil,
            isJsonColumn: cell.column.type?.isJsonType == true,
            isNull: cell.value.isNull,
            isUnloaded: cell.isUnloaded,
            isWritable: isWritable,
            isCheckbox: model.configuration.checkboxColumns.contains(cell.column.dataIndex)
        )
    }

    var holdsOpenEditor: Bool {
        let state = editingState
        return state.session != nil || (state.typedPopover != nil && state.typedPopoverEdits)
    }

    // nil while an editor is open: opening another would close it and drop what it holds.
    func valueEditor(at coord: GridCoord) -> DataGridValueEditor? {
        guard !holdsOpenEditor else { return nil }
        return editCell(at: coord).flatMap(valueEditor(for:))
    }

    static func valueEditorTitle(_ editor: DataGridValueEditor) -> String {
        editor.edits ? String(localized: "Open Value Editor") : String(localized: "View Value")
    }

    // A value that loads into something with no viewer of its own opens the way Return opens it.
    private func openLoadedValueEditor(for target: DataGridEditTarget) {
        guard !holdsOpenEditor, let cell = editCell(for: target) else { return }
        if valueEditor(at: cell.coord) == nil {
            openEditor(at: cell.coord)
        } else {
            openValueEditor(at: cell.coord)
        }
    }

    func openValueEditor(at coord: GridCoord) {
        guard let editor = valueEditor(at: coord), let cell = editCell(at: coord) else { return }
        let target = cell.target
        guard loadsUnloadedValue(of: cell, then: { $0.openLoadedValueEditor(for: target) }) else { return }
        reveal(row: coord.row, displayColumn: coord.displayColumn)
        switch editor {
        case .chevron(let chevron):
            present(chevron, for: cell)
        case .mode(let mode):
            present(mode, for: cell)
        case .jsonViewer:
            showJSONViewer(for: cell)
        case .unloaded:
            // Reached only when a load reported success and left the value on the server.
            NSSound.beep()
        }
    }

    // MARK: - Menu

    @objc func openValueEditor(_ sender: Any?) {
        guard let active = model.selection.activeCell else { return }
        openValueEditor(at: active)
    }

    @objc func openValueEditorFromMenu(_ sender: Any?) {
        guard let focus = commandScope(for: sender).focus else { return }
        openValueEditor(at: focus)
    }

    var canOpenValueEditorForActiveCell: Bool {
        guard let active = model.selection.activeCell else { return false }
        return valueEditor(at: active) != nil
    }

    // Read from keyDown, never a menu key equivalent: AppKit takes an equivalent before a focused field sees the key,
    // and Option-Return is how a field breaks a line.
    func handleValueEditorKey(_ event: NSEvent) -> Bool {
        guard let shortcut = AppSettingsManager.shared.keyboard.shortcut(for: .openValueEditor),
              !shortcut.isCleared, shortcut.matches(event), canOpenValueEditorForActiveCell else { return false }
        openValueEditor(nil)
        return true
    }
}
