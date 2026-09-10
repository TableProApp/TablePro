//
//  NSOpenPanel+Sheet.swift
//  TablePro
//

import AppKit

internal extension NSOpenPanel {
    /// A file picker belongs to the window that asked for it. `runModal()` blocks the whole
    /// app, which strands any sheet already up on that window and lets the picker outlive
    /// the window it was opened from.
    func presentAsSheet(for window: NSWindow?, completion: @escaping (URL?) -> Void) {
        guard let window = window ?? NSApp.keyWindow else {
            completion(runModal() == .OK ? url : nil)
            return
        }
        beginSheetModal(for: window) { [weak self] response in
            completion(response == .OK ? self?.url : nil)
        }
    }
}
