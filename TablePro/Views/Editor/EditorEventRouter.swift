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
        var windowObserver: NSObjectProtocol?
        var needsFirstResponderCheck = false
    }

    private var editors: [ObjectIdentifier: EditorRef] = [:]
    private var rightClickMonitor: Any?
    private var clipboardMonitor: Any?

    private init() {}

    // MARK: - Registration

    internal func register(_ coordinator: SQLEditorCoordinator, textView: TextView) {
        let key = ObjectIdentifier(coordinator)
        editors[key] = EditorRef(coordinator: coordinator, textView: textView)

        if rightClickMonitor == nil {
            installMonitors()
        }

        if textView.window != nil {
            installWindowObserver(for: key)
        } else {
            Task { [weak self] in
                guard let self, self.editors[key]?.windowObserver == nil else { return }
                self.installWindowObserver(for: key)
            }
        }
    }

    internal func unregister(_ coordinator: SQLEditorCoordinator) {
        let key = ObjectIdentifier(coordinator)
        if let observer = editors[key]?.windowObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        editors.removeValue(forKey: key)
        purgeStaleEntries()

        if editors.isEmpty {
            removeMonitors()
        }
    }

    // MARK: - Per-Window Observer

    private func installWindowObserver(for key: ObjectIdentifier) {
        guard editors[key]?.windowObserver == nil,
              let textView = editors[key]?.textView,
              let window = textView.window else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard var ref = self.editors[key], !ref.needsFirstResponderCheck else { return }
                ref.needsFirstResponderCheck = true
                self.editors[key] = ref
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.editors[key]?.needsFirstResponderCheck = false
                    self.editors[key]?.coordinator?.checkFirstResponderChange()
                }
            }
        }
        editors[key]?.windowObserver = observer
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
}
