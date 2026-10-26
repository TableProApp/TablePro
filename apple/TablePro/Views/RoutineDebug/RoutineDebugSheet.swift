//
//  RoutineDebugSheet.swift
//  TablePro
//

import AppKit
import SwiftUI

// A SwiftUI view as a window sheet whose answer is awaited. The coordinator asks from a task, so there is no binding to present from.
@MainActor
internal enum RoutineDebugSheet {
    // A cancelled `setup` answers the sheet as dismissed, the way Cancel would.
    static func present<Value: Sendable, Content: View>(
        on parent: NSWindow,
        setup: RoutineDebugSetup,
        @ViewBuilder content: (@escaping @MainActor (Value?) -> Void) -> Content
    ) async -> Value? {
        guard !setup.isCancelled, parent.attachedSheet == nil else { return nil }
        let presentation = Presentation<Value>(parent: parent)
        let hosting = NSHostingController(rootView: content { presentation.finish($0) })
        let sheet = NSWindow(contentViewController: hosting)
        sheet.isReleasedWhenClosed = false
        presentation.sheet = sheet
        setup.dismissPresentation = { presentation.finish(nil) }
        let value = await withCheckedContinuation { continuation in
            presentation.continuation = continuation
            parent.beginSheet(sheet)
        }
        setup.dismissPresentation = nil
        return value
    }

    @MainActor
    private final class Presentation<Value: Sendable> {
        weak var parent: NSWindow?
        var sheet: NSWindow?
        var continuation: CheckedContinuation<Value?, Never>?

        init(parent: NSWindow) {
            self.parent = parent
        }

        func finish(_ value: Value?) {
            guard let continuation, let sheet else { return }
            self.continuation = nil
            self.sheet = nil
            if let parent {
                parent.endSheet(sheet)
            } else {
                sheet.orderOut(nil)
            }
            // Released on the next turn: the hosting view is still inside the button action that answered.
            Task { @MainActor in
                sheet.contentViewController = nil
            }
            continuation.resume(returning: value)
        }
    }
}
