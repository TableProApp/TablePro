//
//  EditorEventRouter.swift
//  TablePro
//
//  Shared event router that installs one set of process-global monitors
//  and dispatches to the correct editor by window, replacing per-editor monitors.
//

@preconcurrency import AppKit
import CodeEditTextView

@MainActor
internal final class EditorEventRouter {
    internal static let shared = EditorEventRouter()

    private struct EditorRef {
        weak var coordinator: SQLEditorCoordinator?
        weak var textView: TextView?
    }

    private var editors: [ObjectIdentifier: EditorRef] = [:]
    private var rightClickMonitor: Any?
    private var clipboardMonitor: Any?
    private var windowUpdateObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Registration

    internal func register(_ coordinator: SQLEditorCoordinator, textView: TextView) {
        let key = ObjectIdentifier(coordinator)
        editors[key] = EditorRef(coordinator: coordinator, textView: textView)

        if rightClickMonitor == nil {
            installMonitors()
        }
    }

    internal func unregister(_ coordinator: SQLEditorCoordinator) {
        editors.removeValue(forKey: ObjectIdentifier(coordinator))
        purgeStaleEntries()

        if editors.isEmpty {
            removeMonitors()
        }
    }

    // MARK: - Lookup

    private func editor(for window: NSWindow?) -> (SQLEditorCoordinator, TextView)? {
        guard let window else { return nil }
        for ref in editors.values {
            guard let coordinator = ref.coordinator, let textView = ref.textView,
                  textView.window === window else { continue }
            return (coordinator, textView)
        }
        return nil
    }

    private func purgeStaleEntries() {
        editors = editors.filter { $0.value.coordinator != nil && $0.value.textView != nil }
    }

    // MARK: - Monitor Installation

    private func installMonitors() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            nonisolated(unsafe) let event = nsEvent
            return MainActor.assumeIsolated {
                self.handleRightClick(event)
            }
        }

        clipboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] nsEvent in
            guard let self else { return nsEvent }
            nonisolated(unsafe) let event = nsEvent
            return MainActor.assumeIsolated {
                self.handleKeyDown(event)
            }
        }

        windowUpdateObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.handleWindowUpdate(notification)
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
        if let observer = windowUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
            windowUpdateObserver = nil
        }
    }

    // MARK: - Event Handlers

    private func handleRightClick(_ event: NSEvent) -> NSEvent? {
        guard let (coordinator, textView) = editor(for: event.window) else { return event }

        let locationInView = textView.convert(event.locationInWindow, from: nil)
        guard textView.bounds.contains(locationInView) else { return event }

        coordinator.showContextMenu(for: event, in: textView)
        return nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let (_, textView) = editor(for: event.window),
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

    private func handleWindowUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let (coordinator, _) = editor(for: window) else { return }
        coordinator.checkFirstResponderChange()
    }
}
