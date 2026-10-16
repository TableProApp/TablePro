//
//  SetValueOptions.swift
//  TablePro
//

import Foundation

enum SetValueCommand: Hashable, Sendable {
    case empty
    case null
    case defaultValue
    case expression(CellExpression)
    case uuid(UUIDVersion)
}

/// What the writer that saves this table can take beyond plain values.
struct CellWriterSupport: Sendable, Equatable {
    var acceptsExpressions: Bool
    var acceptsUUIDText: Bool

    static let none = CellWriterSupport(acceptsExpressions: false, acceptsUUIDText: false)
    /// The host's `SQLStatementGenerator`, which writes both.
    static let host = CellWriterSupport(acceptsExpressions: true, acceptsUUIDText: true)
}

struct SetValueContext: Sendable {
    var columnType: ColumnType?
    var isNullable: Bool
    var serverAssignsValue: Bool
    var isForeignKey: Bool
    var isWritable: Bool
    var displayFormat: ValueDisplayFormat?
    var sampleText: String?
    var declaredType: String?
    var databaseType: DatabaseType
    var rowIsInserted: Bool
    var writer: CellWriterSupport

    init(
        columnType: ColumnType?,
        isNullable: Bool,
        serverAssignsValue: Bool,
        isForeignKey: Bool,
        isWritable: Bool,
        displayFormat: ValueDisplayFormat? = nil,
        sampleText: String? = nil,
        declaredType: String? = nil,
        databaseType: DatabaseType,
        rowIsInserted: Bool,
        writer: CellWriterSupport
    ) {
        self.columnType = columnType
        self.isNullable = isNullable
        self.serverAssignsValue = serverAssignsValue
        self.isForeignKey = isForeignKey
        self.isWritable = isWritable
        self.displayFormat = displayFormat
        self.sampleText = sampleText
        self.declaredType = declaredType
        self.databaseType = databaseType
        self.rowIsInserted = rowIsInserted
        self.writer = writer
    }
}

/// The values a cell can be set to without typing, in menu order. Every surface that offers Set Value reads this,
/// so the grid, the menu bar and the inspector cannot disagree about what a column takes.
enum SetValueOptions {
    static func commands(for context: SetValueContext) -> [SetValueCommand] {
        guard context.isWritable else { return [] }
        var commands: [SetValueCommand] = []
        if context.columnType?.hasEmptyValue ?? true {
            commands.append(.empty)
        }
        if context.isNullable {
            commands.append(.null)
        }
        if context.serverAssignsValue,
           context.rowIsInserted || CellExpressionVocabulary.updateTakesDefault(context.databaseType) {
            commands.append(.defaultValue)
        }
        if context.writer.acceptsExpressions {
            commands += CellExpressionVocabulary
                .expressions(for: context.databaseType, columnType: context.columnType)
                .map(SetValueCommand.expression)
        }
        if uuidForm(for: context) != nil {
            commands += [.uuid(.v4), .uuid(.v7)]
        }
        return commands
    }

    /// Nil wherever Generate UUID is not offered. A foreign key takes a value that exists in the table it points at,
    /// which a new UUID never does.
    static func uuidForm(for context: SetValueContext) -> UUIDCellForm? {
        guard context.isWritable, !context.isForeignKey, context.writer.acceptsUUIDText else { return nil }
        return UUIDCellForm(
            columnType: context.columnType,
            displayFormat: context.displayFormat,
            sampleText: context.sampleText,
            declaredType: context.declaredType
        )
    }

    static func title(for command: SetValueCommand) -> String {
        switch command {
        case .empty:
            String(localized: "Empty")
        case .null:
            String(localized: "NULL")
        case .defaultValue:
            String(localized: "Default")
        case .expression(let expression):
            expression.sql
        case .uuid(.v4):
            String(localized: "Generate UUID")
        case .uuid(.v7):
            String(localized: "Generate UUIDv7")
        }
    }
}
