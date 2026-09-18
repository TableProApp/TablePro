//
//  DataGridRowReorder.swift
//  TablePro
//

import Foundation

/// Whether this grid offers row reordering, and what to tell the user when it does not.
///
/// The grid used to infer this from `delegate != nil`, which is true of every grid in the app, so
/// it registered the drag type, answered a drop with `.move` and accepted it on engines that could
/// not reorder anything. The handler behind it was optional and evaluated to nothing, so the row
/// lifted, the insertion gap opened, the drop was taken and nothing happened.
struct DataGridRowReorder: Equatable {
    var isEnabled: Bool
    /// Shown as a help tag on the row number, which is the handle the drag starts from. Nil where
    /// the grid never offers reordering at all and the absence needs no explaining.
    var unavailableReason: String?

    init(isEnabled: Bool = false, unavailableReason: String? = nil) {
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
    }

    static let disabled = DataGridRowReorder()
}
