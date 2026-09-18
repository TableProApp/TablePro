//
//  InspectorViewMode.swift
//  TablePro
//

import Foundation

/// Which rendering of the selected row the inspector is showing.
///
/// Both modes describe the same object, which is what makes a segmented control the right
/// affordance for them: the HIG's inspector guidance covers switching between views of the current
/// selection, and fields and JSON are two views of one row. The assistant used to sit beside them
/// as a third segment, which is what made the pane untitleable, and it is now its own surface.
internal enum InspectorViewMode: String, CaseIterable, Hashable {
    case fields
    case json

    internal var localizedTitle: String {
        switch self {
        case .fields: String(localized: "Fields")
        case .json: String(localized: "JSON")
        }
    }
}
