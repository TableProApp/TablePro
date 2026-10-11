//
//  GeometryFieldDescriptor.swift
//  TablePro
//

import Foundation

internal enum GeometryTextEditor: Equatable, Sendable {
    case multiLine
    case json
    case hex
}

/// Named for what picks the reader, not for the editor: a spatial column can hold JSON-shaped text
/// that is not GeoJSON, and only a JSON column is held to the narrow GeoJSON reader.
internal enum GeometryFieldSource: Equatable, Sendable {
    case spatialColumn
    case jsonColumn
    case binary
}

internal struct GeometryFieldDescriptor: Equatable, Sendable {
    let textEditor: GeometryTextEditor
    let source: GeometryFieldSource
}
