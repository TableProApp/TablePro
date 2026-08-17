//
//  DatabaseTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of the object tree. All the hosting geometry is `SidebarHostingCellView`'s; this only
/// knows how to turn a node into the row it draws.
final class DatabaseTreeCellView: SidebarHostingCellView<DatabaseTreeRowView> {
    func configure(
        node: DatabaseTreeNode,
        isFavorite: Bool,
        context: DatabaseTreeRowContext,
        actions: DatabaseTreeRowActions
    ) {
        update(rootView: DatabaseTreeRowView(
            node: node,
            isFavorite: isFavorite,
            context: context,
            actions: actions
        ))
    }
}
