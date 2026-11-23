import AppKit

// Option-click on a close button asks every window in turn within one event. The windows holding
// work answer one Review Changes alert, as a document-based app's do, not one sheet each.
@MainActor
internal final class WindowCloseReview {
    internal static let shared = WindowCloseReview()

    internal enum Answer: Equatable {
        case review
        case discard
        case cancel
    }

    internal struct Entry {
        let actions: MainContentCommandActions
        weak var window: NSWindow?
    }

    internal var ask: (_ windowCount: Int, _ work: [RunningWork], _ anchor: NSWindow?) async -> Answer = { count, work, anchor in
        await WindowCloseReview.askModally(windowCount: count, work: work, anchor: anchor)
    }

    private var collecting: (event: NSEvent, entries: [Entry], review: Task<Void, Never>)?

    internal static func closesEveryWindow(_ event: NSEvent?) -> Bool {
        guard let event, event.modifierFlags.contains(.option) else { return false }
        return event.type == .leftMouseDown || event.type == .leftMouseUp
    }

    // Every window enlisted for one event shares the returned task, which starts once AppKit has asked them all.
    internal func enlist(_ actions: MainContentCommandActions, window: NSWindow, for event: NSEvent) -> Task<Void, Never> {
        if let collecting, collecting.event === event {
            self.collecting?.entries.append(Entry(actions: actions, window: window))
            return collecting.review
        }
        let review = Task { await self.runCollected() }
        collecting = (event, [Entry(actions: actions, window: window)], review)
        return review
    }

    private func runCollected() async {
        guard let entries = collecting?.entries else { return }
        collecting = nil
        await review(entries)
    }

    internal func review(_ entries: [Entry]) async {
        guard entries.count > 1 else {
            if let only = entries.first { _ = await only.actions.closeWindowAwaiting(asBatchSurvivor: false) }
            return
        }
        let work = entries.flatMap { $0.actions.workInWindow }
        let windows = entries.compactMap { $0.window }
        let anchor = windows.first { $0.isKeyWindow } ?? windows.first
        switch await ask(entries.count, work, anchor) {
        case .review:
            for entry in entries {
                // Asked again per window: another close can take one while an earlier window's question is up.
                guard let window = Self.openWindow(of: entry) else { continue }
                window.makeKeyAndOrderFront(nil)
                // Cancel on one window ends the review, as it does in a document-based app.
                guard await entry.actions.closeWindowAwaiting(asBatchSurvivor: false) == .closed else { return }
            }
        case .discard:
            for entry in entries where Self.openWindow(of: entry) != nil {
                entry.actions.discardWorkAndCloseWindow()
            }
        case .cancel:
            return
        }
    }

    // A window already closed is left alone: with its coordinator gone, its actions would close the key window instead.
    private static func openWindow(of entry: Entry) -> NSWindow? {
        guard let window = entry.window,
              window.isVisible || window.isMiniaturized,
              entry.actions.coordinator?.contentWindow === window
        else { return nil }
        return window
    }

    private static func askModally(windowCount: Int, work: [RunningWork], anchor: NSWindow?) async -> Answer {
        let alert = NSAlert()
        alert.messageText = String(
            format: String(localized: "You have %lld windows with unsaved changes. Do you want to review these changes before closing?"),
            windowCount
        )
        alert.informativeText = RunningWorkPrompt.saveMessage(
            String(localized: "If you don't review your windows, all your changes will be lost."),
            action: .close,
            alsoStopping: work
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Review Changes…"))
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        let discard = alert.addButton(withTitle: String(localized: "Discard Changes"))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        switch await AlertHelper.response(to: alert, in: anchor) {
        case .alertFirstButtonReturn: return .review
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }
}
