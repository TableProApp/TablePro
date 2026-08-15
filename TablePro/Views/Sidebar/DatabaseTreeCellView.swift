//
//  DatabaseTreeCellView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// One row of the object tree. All the hosting geometry is `SidebarHostingCellView`'s; this only
/// knows how to turn a node into the row it draws.
final class DatabaseTreeCellView: SidebarHostingCellView<DatabaseTreeRowView> {
    func configure(node: DatabaseTreeNode, context: DatabaseTreeRowContext, actions: DatabaseTreeRowActions) {
        update(rootView: DatabaseTreeRowView(node: node, context: context, actions: actions))
    }
}
