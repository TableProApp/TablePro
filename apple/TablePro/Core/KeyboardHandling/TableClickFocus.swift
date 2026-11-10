import AppKit

// On macOS 27 a click on a SwiftUI List or Table row leaves the backing table without first
// responder (FB25239926), so the selection draws grey and keys reach the previous responder.
@MainActor
final class TableClickFocus {
    static let shared = TableClickFocus()

    // What held the keyboard when the press began. A field editor serves every field, so the control it edits counts too.
    @MainActor
    private struct Holder {
        weak var responder: NSResponder?
        weak var editedControl: AnyObject?

        init(_ responder: NSResponder?) {
            self.responder = responder
            editedControl = (responder as? NSTextView)?.delegate
        }

        func isStill(_ current: NSResponder?) -> Bool {
            current != nil && current === responder && (current as? NSTextView)?.delegate === editedControl
        }
    }

    private var monitor: Any?
    private weak var pendingWindow: NSWindow?
    private weak var pendingTable: NSTableView?
    private var pendingHolder = Holder(nil)

    init() {}

    func install() {
        guard monitor == nil, #available(macOS 27, *) else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { nsEvent in
            nonisolated(unsafe) let event = nsEvent
            MainActor.assumeIsolated { Self.shared.handle(event) }
            return nsEvent
        }
    }

    func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown(event)
        case .leftMouseUp: mouseUp()
        default: break
        }
    }

    private func mouseDown(_ event: NSEvent) {
        pendingWindow = nil
        pendingTable = nil
        guard !event.modifierFlags.contains(.control),
              let window = event.window,
              window.attachedSheet == nil,
              NSApp.modalWindow.map({ $0 === window }) ?? true,
              let hit = window.contentView?.superview?.hitTest(event.locationInWindow),
              !hit.acceptsFirstResponder,
              let table = Self.enclosingTable(of: hit),
              !Self.runsItsOwnMouseDown(table),
              table.acceptsFirstResponder,
              !Self.holdsFocus(table, in: window) else { return }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        // A press on a selected row changes no selection, and its mouse-up can end in a tracking loop the monitor never sees.
        if row >= 0, table.selectedRowIndexes.contains(row) {
            window.makeFirstResponder(table)
            return
        }
        // Claimed before SwiftUI handles the mouse-up, the click can lose its selection.
        pendingWindow = window
        pendingTable = table
        pendingHolder = Holder(window.firstResponder)
    }

    private func mouseUp() {
        guard let window = pendingWindow, let table = pendingTable else { return }
        let holder = pendingHolder
        pendingWindow = nil
        pendingTable = nil
        DispatchQueue.main.async {
            guard table.window === window, !Self.holdsFocus(table, in: window) else { return }
            // A focus the click itself moved elsewhere stays; one it left vacant or untouched goes to the table.
            let current = window.firstResponder
            guard current == nil || current === window || holder.isStill(current) else { return }
            window.makeFirstResponder(table)
        }
    }

    // The bug is in tables SwiftUI defines; AppKit's own and the app's subclasses take focus in NSTableView.mouseDown.
    private static func runsItsOwnMouseDown(_ table: NSTableView) -> Bool {
        let bundle = Bundle(for: type(of: table))
        return bundle == Bundle(for: NSTableView.self) || bundle == Bundle.main
    }

    private static func enclosingTable(of view: NSView) -> NSTableView? {
        var current: NSView? = view
        while let candidate = current {
            if let table = candidate as? NSTableView { return table }
            current = candidate.superview
        }
        return nil
    }

    private static func holdsFocus(_ table: NSTableView, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === table || responder.isDescendant(of: table)
    }
}
