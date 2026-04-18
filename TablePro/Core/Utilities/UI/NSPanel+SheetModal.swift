//
//  NSPanel+SheetModal.swift
//  TablePro
//

import AppKit

extension NSSavePanel {
    @MainActor
    func presentAsSheet(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            self.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}

