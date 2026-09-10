//
//  PluginCellValue+DefaultMarker.swift
//  TablePro
//

import Foundation
import TableProPluginKit

internal extension PluginCellValue {
    /// The sentinel a pending inserted row carries for a column the server fills in, written by
    /// `RowOperationsManager` and stripped again by `SQLStatementGenerator`.
    ///
    /// It is an internal marker, never a value, so every view that renders a cell has to recognise
    /// it. The grid shows it as a placeholder; anything that renders the same rows some other way
    /// has to agree, or the marker leaks out as literal text.
    static let defaultMarkerText = "__DEFAULT__"

    var isDefaultMarker: Bool {
        guard case .text(let value) = self else { return false }
        return value == Self.defaultMarkerText
    }
}
