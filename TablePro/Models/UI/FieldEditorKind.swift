//
//  FieldEditorKind.swift
//  TablePro
//

import Foundation

internal enum FieldEditorKind: Equatable {
    case json
    case phpSerialized
    case image(CellImageFormat)
    case blobHex
    case boolean
    case enumPicker(values: [String])
    case setPicker(values: [String])
    case typePicker
    /// A value with suggestions the user may ignore: the menu writes correct SQL, typing writes
    /// your own. `enumPicker` cannot serve, because its list is the whole set of legal values.
    case valuePicker(options: [GridMenuOption])
    case schemaText
    case multiLine
    case singleLine
}
