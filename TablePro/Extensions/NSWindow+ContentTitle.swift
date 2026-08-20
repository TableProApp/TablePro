//
//  NSWindow+ContentTitle.swift
//  TablePro
//

import AppKit

internal extension NSWindow {
    /// `NSWindow(contentViewController:)` binds the window title to that controller's `title`
    /// with "Untitled" as its null placeholder, so a window built that way is titled through its
    /// content view controller. Writing `window.title` afterwards holds only until the binding
    /// next fires, and the placeholder is what a controller with no title publishes.
    static func titled(_ title: String, contentViewController: NSViewController) -> NSWindow {
        contentViewController.title = title
        return NSWindow(contentViewController: contentViewController)
    }
}
