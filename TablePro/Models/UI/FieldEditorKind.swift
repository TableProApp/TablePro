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
    /// An ordered list of elements, each edited on its own. The payload says whether an element is
    /// a one-line value or a JSON document, which are two different editors over the same list.
    case arrayElements(element: ArrayElementEditor, values: [String])
    case typePicker
    /// A value with suggestions the user may ignore: the menu writes correct SQL, typing writes
    /// your own. `enumPicker` cannot serve, because its list is the whole set of legal values.
    case valuePicker(options: [GridMenuOption])
    case schemaText
    case multiLine
    case singleLine
}
