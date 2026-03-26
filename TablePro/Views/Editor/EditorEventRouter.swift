//
//  EditorEventRouter.swift
//  TablePro
//
//  Shared event router that installs one set of process-global monitors
//  and dispatches to the correct editor by window.
//

@preconcurrency import AppKit

@MainActor
internal final class EditorEventRouter {
    internal static let shared = EditorEventRouter()

    private struct EditorRef {
        weak var textView: TPTextView?
        var windowObserver: NSObjectProtocol?
    }

    private var editors: [ObjectIdentifier: EditorRef] = [:]
    private var rightClickMonitor: Any?
    private var clipboardMonitor: Any?

    private init() {}

    // MARK: - Registration

    internal func register(textView: TPTextView) {
        let key = ObjectIdentifier(textView)
        editors[key] = EditorRef(textView: textView)

        if rightClickMonitor == nil {
            installMonitors()
        }
    }

    internal func unregister(textView: TPTextView) {
        let key = ObjectIdentifier(textView)
        if let observer = editors[key]?.windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        editors.removeValue(forKey: key)
        purgeStaleEntries()

        if editors.isEmpty {
            removeMonitors()
        }
    }

    // MARK: - Lookup

    private func textView(for window: NSWindow?) -> TPTextView? {
        guard let window else { return nil }
        for ref in editors.values {
            guard let textView = ref.textView, textView.window === window else { continue }
            return textView
        }
        return nil
    }

    private func purgeStaleEntries() {
        editors = editors.filter { $0.value.textView != nil }
    }

    // MARK: - Monitor Installation

    private func installMonitors() {
        clipboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            nonisolated(unsafe) let event = nsEvent
            return MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }
    }

    private func removeMonitors() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
        if let monitor = clipboardMonitor {
            NSEvent.removeMonitor(monitor)
            clipboardMonitor = nil
        }
    }

    // MARK: - Event Handlers

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let textView = textView(for: event.window),
              textView.window?.firstResponder === textView else {
            return event
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command),
              !mods.contains(.shift), !mods.contains(.option), !mods.contains(.control) else {
            return event
        }

        let range = textView.selectedRange()
        guard range.length > 0 else { return event }
        let text = (textView.string as NSString).substring(with: range)

        switch event.keyCode {
        case 8: // Cmd+C
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return nil
        case 7: // Cmd+X
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            textView.replaceCharacters(in: range, with: "")
            return nil
        default:
            break
        }

        return event
    }
}
