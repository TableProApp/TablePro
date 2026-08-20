//
//  KeyRepeatFilter.swift
//  TablePro
//
//  Drops OS key auto-repeat for actions that must fire once per physical press.
//  SwiftUI `.commands` key-equivalents auto-repeat while held, but menu actions
//  like Refresh should fire once per press, matching standard macOS behaviour.
//

import AppKit

@MainActor
final class KeyRepeatFilter {
    static let shared = KeyRepeatFilter()

    private static let nonRepeatingActions: [ShortcutAction] = [.refresh]

    private var monitor: Any?

    private init() {}

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { nsEvent in
            nonisolated(unsafe) let event = nsEvent
            let suppress = MainActor.assumeIsolated { () -> Bool in
                guard event.isARepeat else { return false }
                let keyboard = AppSettingsManager.shared.keyboard
                return Self.nonRepeatingActions.contains {
                    keyboard.shortcut(for: $0)?.matches(event) == true
                }
            }
            return suppress ? nil : nsEvent
        }
    }
}
