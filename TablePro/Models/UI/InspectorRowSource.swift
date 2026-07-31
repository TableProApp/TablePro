//
//  InspectorRowSource.swift
//  TablePro
//
//  Lets the grid that owns the current selection supply the inspector's
//  fields and receive its edits, instead of the inspector assuming every
//  selection indexes the data tab's rows.
//

import Foundation

internal struct InspectorRowField: Equatable {
    let name: String
    let value: String?
    let editor: FieldEditorKind
    let isModified: Bool

    init(name: String, value: String?, editor: FieldEditorKind, isModified: Bool = false) {
        self.name = name
        self.value = value
        self.editor = editor
        self.isModified = isModified
    }
}

internal struct InspectorRow: Equatable {
    let fields: [InspectorRowField]
    let isEditable: Bool
}

@MainActor
internal protocol InspectorRowSource: AnyObject {
    func inspectorRow(atDisplayRow displayRow: Int) -> InspectorRow?
    func commitInspectorField(displayRow: Int, fieldIndex: Int, value: String?)
}
