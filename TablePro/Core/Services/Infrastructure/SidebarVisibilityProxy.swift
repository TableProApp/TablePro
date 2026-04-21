//
//  SidebarVisibilityProxy.swift
//  TablePro
//
//  Protocol for coordinator → split view controller sidebar toggle.
//

import Foundation

@MainActor
internal protocol SidebarVisibilityProxy: AnyObject {
    var isSidebarVisible: Bool { get }
    func showSidebar()
    func hideSidebar()
    func toggleSidebar()
}

internal extension SidebarVisibilityProxy {
    func toggleSidebar() {
        if isSidebarVisible { hideSidebar() } else { showSidebar() }
    }
}
