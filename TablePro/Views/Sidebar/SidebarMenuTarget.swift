//
//  SidebarMenuTarget.swift
//  TablePro
//

import Foundation

/// Resolves which rows a contextual menu acts on, following AppKit's convention for
/// `NSTableView.clickedRow`: a menu applies to the whole selection when the clicked row
/// is part of it, and to the clicked row alone otherwise.
enum SidebarMenuTarget {
    static func resolve<Element: Hashable>(clicked: Element?, selection: [Element]) -> [Element] {
        guard let clicked else { return selection }
        guard selection.contains(clicked) else { return [clicked] }
        return selection
    }

    static func resolveContainers(
        clicked: DatabaseContainerRef,
        selection: [DatabaseContainerRef]
    ) -> [DatabaseContainerRef] {
        resolve(clicked: clicked, selection: selection.matching(kind: clicked.kind)).sortedByName
    }
}
