//
//  DataGridCommands+FillColumn.swift
//  TablePro
//

import AppKit
import TableProPluginKit

enum FillColumnChoice: Equatable {
    case value
    case null
    case uuid(UUIDVersion)
}

// A UUID is drawn for each row.
enum FillColumnContent: Equatable {
    case value(PluginCellValue, isExpression: Bool = false)
    case uuid(UUIDVersion, UUIDCellForm)
}

extension DataGridCommands {
    // Writable, loaded rows the reader can see; a key column takes no fill, since every row would collide.
    func canFillColumn(_ column: DataGridColumn) -> Bool {
        configuration.isEditable
            && model.rowCount > 0
            && model.isColumnWritable(column)
            && !configuration.primaryKeyColumns.contains(column.name)
    }

    func fillTargetRowIDs() -> [RowID] {
        guard configuration.isEditable else { return [] }
        let rows = model.rows
        return (0..<model.rowCount).compactMap { displayRow in
            guard let rowID = model.order.rowID(at: displayRow, in: rows), !isRowDeleted(rowID) else { return nil }
            return rowID
        }
    }

    func fillColumnChoices(for column: DataGridColumn) -> [FillColumnChoice] {
        let rows = model.rows
        guard rows.columns.indices.contains(column.dataIndex) else { return [.value] }
        var choices: [FillColumnChoice] = [.value]
        if rows.columnNullable[column.name] ?? true {
            choices.append(.null)
        }
        if fillUUIDForm(for: column) != nil {
            choices += [.uuid(.v4), .uuid(.v7)]
        }
        return choices
    }

    // The value is read the way a typed cell is. Nil when the column holds neither the text nor NULL in its place.
    func fillColumnContent(choice: FillColumnChoice, text: String, column: DataGridColumn) -> FillColumnContent? {
        switch choice {
        case .value:
            return enteredCell(text, column: column).map { FillColumnContent.value($0.value, isExpression: $0.isExpression) }
        case .null:
            return .value(.null)
        case .uuid(let version):
            return fillUUIDForm(for: column).map { FillColumnContent.uuid(version, $0) }
        }
    }

    private func fillUUIDForm(for column: DataGridColumn) -> UUIDCellForm? {
        setValueContext(for: column, rowIsInserted: false).flatMap { SetValueOptions.uuidForm(for: $0) }
    }

    // One commit for the whole column; rows that already hold the value are left as they are.
    func applyFillColumn(_ column: DataGridColumn, content: FillColumnContent) {
        fill(fillTargetRowIDs(), column: column, content: content)
    }

    // The retry keeps these rows: a filter changed while values load must not move the fill onto others.
    private func fill(_ targets: [RowID], column: DataGridColumn, content: FillColumnContent) {
        guard !targets.isEmpty else { return }
        guard loader.ensureLoaded(targets, columns: IndexSet(integer: column.dataIndex), in: model, retry: {
            fill(targets, column: column, content: content)
        }) else { return }
        let edits = targets.map { rowID in
            let staged = Self.fillValue(content)
            return DataGridCellEdit(rowID: rowID, columnID: column.id, value: .value(staged.value, isExpression: staged.isExpression))
        }
        model.commit(edits, actionName: String(localized: "Fill Column"))
    }

    private static func fillValue(_ content: FillColumnContent) -> StagedCellEntry {
        switch content {
        case .value(let value, let isExpression):
            return (value: value, isExpression: isExpression)
        case .uuid(let version, let form):
            return (value: form.value(for: UUIDValueGenerator.shared.make(version)), isExpression: false)
        }
    }

    static func fillImpactDescription(rowCount: Int) -> String {
        if rowCount == 1 {
            return String(localized: "This sets 1 loaded row. Review and Save to apply.")
        }
        return String(
            format: String(localized: "This sets %lld loaded rows. Review and Save to apply."),
            Int64(rowCount)
        )
    }
}

// Value, NULL and the UUIDs are radio buttons with one superview and one action, which AppKit groups by itself.
@MainActor
final class FillColumnAccessoryView: NSView {
    private static let width: CGFloat = 260
    private static let valueRowHeight: CGFloat = 24
    private static let choiceRowHeight: CGFloat = 22

    private let valueField = NSTextField(frame: .zero)
    private var radios: [(choice: FillColumnChoice, button: NSButton)] = []

    init(choices: [FillColumnChoice]) {
        let others = choices.filter { $0 != .value }
        let height = Self.valueRowHeight + CGFloat(others.count) * Self.choiceRowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: height))

        valueField.usesSingleLineMode = true
        valueField.placeholderString = String(localized: "Value")
        valueField.setAccessibilityLabel(String(localized: "Value"))
        addSubview(valueField)

        let valueRowY = height - Self.valueRowHeight
        guard !others.isEmpty else {
            valueField.frame = NSRect(x: 0, y: valueRowY, width: Self.width, height: Self.valueRowHeight)
            return
        }

        let valueRadio = addRadio(.value, at: valueRowY, rowHeight: Self.valueRowHeight)
        valueRadio.state = .on
        let fieldX = valueRadio.frame.maxX + 6
        valueField.frame = NSRect(x: fieldX, y: valueRowY, width: Self.width - fieldX, height: Self.valueRowHeight)
        for (index, choice) in others.enumerated() {
            addRadio(choice, at: valueRowY - CGFloat(index + 1) * Self.choiceRowHeight, rowHeight: Self.choiceRowHeight)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var enteredText: String { valueField.stringValue }

    var choice: FillColumnChoice {
        radios.first { $0.button.state == .on }?.choice ?? .value
    }

    var firstResponderView: NSView { valueField }

    @discardableResult
    private func addRadio(_ choice: FillColumnChoice, at rowY: CGFloat, rowHeight: CGFloat) -> NSButton {
        let button = NSButton(radioButtonWithTitle: Self.title(for: choice), target: self, action: #selector(choiceChanged))
        button.sizeToFit()
        button.frame.origin = NSPoint(x: 0, y: rowY + (rowHeight - button.frame.height) / 2)
        addSubview(button)
        radios.append((choice, button))
        return button
    }

    private static func title(for choice: FillColumnChoice) -> String {
        switch choice {
        case .value: String(localized: "Value")
        case .null: String(localized: "NULL")
        case .uuid(.v4): String(localized: "New UUID")
        case .uuid(.v7): String(localized: "New UUIDv7")
        }
    }

    @objc private func choiceChanged() {
        valueField.isEnabled = choice == .value
    }
}
