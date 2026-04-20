//
//  InspectorVisibilityProxy.swift
//  TablePro
//
//  Protocol for coordinator → split view controller inspector toggle.
//

import Foundation

@MainActor
internal protocol InspectorVisibilityProxy: AnyObject {
    var isInspectorVisible: Bool { get }
    func showInspector()
    func hideInspector()
    func toggleInspector()
}

internal extension InspectorVisibilityProxy {
    func toggleInspector() {
        if isInspectorVisible { hideInspector() } else { showInspector() }
    }
}
