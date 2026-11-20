//
//  CellInteractionResolver.swift
//  TablePro
//

import Foundation

internal struct CellContext: Equatable {
    let columnType: ColumnType?
    let value: String?
    let isTableEditable: Bool
    let isRowDeleted: Bool
    let isImmutableColumn: Bool
    let isBinaryValue: Bool
    let isForeignKey: Bool
    let displayFormatOverride: ValueDisplayFormat?
    // Resolved by the caller that holds the typed cell, so the row inspector and the grid reach one answer.
    let detectedContent: CellValueContent

    init(
        columnType: ColumnType?,
        value: String?,
        isTableEditable: Bool,
        isRowDeleted: Bool,
        isImmutableColumn: Bool,
        isBinaryValue: Bool = false,
        isForeignKey: Bool = false,
        displayFormatOverride: ValueDisplayFormat? = nil,
        detectedContent: CellValueContent = .plain
    ) {
        self.columnType = columnType
        self.value = value
        self.isTableEditable = isTableEditable
        self.isRowDeleted = isRowDeleted
        self.isImmutableColumn = isImmutableColumn
        self.isBinaryValue = isBinaryValue
        self.isForeignKey = isForeignKey
        self.displayFormatOverride = displayFormatOverride
        self.detectedContent = detectedContent
    }
}

internal enum CellInteractionMode: Equatable {
    case viewText(value: String)
    case viewJson
    case viewBlob
    case viewPhpSerialized
    case viewBinaryValue(BinaryValueFormat)

    case viewSvg
    case viewVector

    case editInline(value: String)
    case editText(value: String)
    case editForeignKey
    case editJson
    case editBlob
    case editSvg
    case editVector

    case blocked
}

internal struct CellInteractionResolver {
    static let inlineLengthLimit = 256

    static func editsInPopover(_ text: String) -> Bool {
        (text as NSString).length > inlineLengthLimit || text.containsLineBreak
    }

    func resolve(_ context: CellContext) -> CellInteractionMode {
        guard !context.isRowDeleted else { return .blocked }

        let isReadOnly = !context.isTableEditable || context.isImmutableColumn
        let holdsBytes = context.columnType?.isBlobType == true || context.isBinaryValue

        // Read-only: nothing writes a decoded tree back. A NULL keeps the hex editor, the way bytes get into it.
        if let override = context.displayFormatOverride, let format = override.binaryValueFormat,
           context.isBinaryValue || context.value != nil,
           holdsBytes || override.isApplicable(to: context.columnType) {
            return .viewBinaryValue(format)
        }

        if holdsBytes {
            return isReadOnly ? .viewBlob : .editBlob
        }

        // Ahead of the display format: a vector column offers none, so an override is one left from its text days.
        if opensVectorViewer(context) {
            return isReadOnly ? .viewVector : .editVector
        }

        // An explicit structured format wins over content detection, as it does in the row inspector
        // (FieldEditorResolver); Raw opts out of detection entirely.
        switch context.displayFormatOverride {
        case .json:
            return isReadOnly ? .viewJson : .editJson
        case .phpSerialized:
            return .viewPhpSerialized
        case .raw:
            return plainText(for: context, isReadOnly: isReadOnly)
        case .text, .uuid, .uuidSwappedTime, .unixTimestamp, .unixTimestampMillis, .messagePack, .protobuf,
             .igbinary, .avro, .protobufSchema, .schemaRegistry, .none:
            break
        }

        // Content detected in the cell opens its viewer, the way the row inspector does. The PHP viewer
        // is read-only, and no detector can perfectly tell a serialized value from text that merely
        // looks like one, so auto-detection opens it only where the cell is already read-only: an
        // editable cell keeps its text editor and loses nothing, and a false positive on a read-only
        // cell is harmless (the viewer says it could not parse). Display As > PHP Serialized still opts
        // an editable column in. JSON keeps its column type's inline edit and chevron viewer.
        switch context.detectedContent {
        case .image(.svg):
            return isReadOnly ? .viewSvg : .editSvg
        case .phpSerialized where isReadOnly:
            return .viewPhpSerialized
        case .phpSerialized, .json, .image, .plain:
            break
        }

        return plainText(for: context, isReadOnly: isReadOnly)
    }

    // Last, so a foreign key holding a blob or JSON keeps the editor its content needs.
    private func plainText(for context: CellContext, isReadOnly: Bool) -> CellInteractionMode {
        if isReadOnly {
            return .viewText(value: context.value ?? "NULL")
        }
        if context.isForeignKey { return .editForeignKey }
        let value = context.value ?? ""
        if Self.editsInPopover(value) { return .editText(value: value) }
        return .editInline(value: value)
    }

    // The value decides, as it does for an array: NULL and text the viewer cannot list keep the text editor.
    private func opensVectorViewer(_ context: CellContext) -> Bool {
        guard context.columnType?.isVectorType == true, let value = context.value else { return false }
        return VectorLiteral.isVectorText(value)
    }
}
