//
//  WindowTabGroupOrder.swift
//  TablePro
//

import AppKit
import Foundation

/// Where a window sits in its native tab group, left to right. This is the one definition of window
/// order that both halves of tab persistence use: the save side stamps each tab with its window's
/// position, and a restoring window claims the position it occupies. Deriving the two from different
/// sets would silently misfile tabs, because a window with no live session has no coordinator to be
/// counted among but still occupies a tab.
///
/// It reads `NSWindow.tabbedWindows` rather than any of TablePro's own registries because AppKit
/// populates that at window creation and a lost session never touches it, while `WindowLifecycleMonitor`
/// only learns about a window once its SwiftUI content mounts, which is mid-flight during a reconnect.
internal enum WindowTabGroupOrder {
    internal static func windows(containing window: NSWindow) -> [NSWindow] {
        window.tabbedWindows ?? [window]
    }

    /// Position of `window` among the windows sharing its tab group. A window that reports no tab
    /// group is alone, which is position zero: the same answer as the only window of a connection.
    internal static func index(of window: NSWindow) -> Int {
        position(of: ObjectIdentifier(window), in: windows(containing: window).map(ObjectIdentifier.init))
    }

    internal static func size(containing window: NSWindow) -> Int {
        windows(containing: window).count
    }

    internal static func position(of window: ObjectIdentifier, in group: [ObjectIdentifier]) -> Int {
        group.firstIndex(of: window) ?? 0
    }
}
