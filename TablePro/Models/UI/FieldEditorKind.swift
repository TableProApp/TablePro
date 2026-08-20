//
//  FieldEditorKind.swift
//  TablePro
//

import Foundation

internal enum FieldEditorKind: Equatable {
    case json
    case phpSerialized
    case blobHex
    case boolean
    case enumPicker(values: [String])
    case setPicker(values: [String])
    case typePicker
    case schemaText
    case multiLine
    case singleLine
}
