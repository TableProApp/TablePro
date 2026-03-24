//
//  NSApplication+WindowManagement.swift
//  TablePro
//
//  Window management helpers.
//  Note: Now that macOS 14 is the minimum, SwiftUI's dismissWindow(id:) is available.
//  This extension could be replaced with the native API in a future refactor.
//

import AppKit

extension NSApplication {
    /// Close all windows whose identifier matches the given ID (exact or SwiftUI-suffixed).
    /// SwiftUI appends "-AppWindow-N" to WindowGroup IDs, so we match by prefix.
    func closeWindows(withId id: String) {
        for window in windows {
            guard let rawValue = window.identifier?.rawValue else { continue }
            if rawValue == id || rawValue.hasPrefix("\(id)-") {
                window.close()
            }
        }
    }
}
