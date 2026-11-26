import AppKit

@MainActor
enum KeyboardPresetActions {
    static func choose(_ choice: KeyboardPresetChoice, window: NSWindow?) async -> Bool {
        await choose(choice, in: AppSettingsManager.shared.keyboardSlice, window: window)
    }

    // One write, so the menus, toolbar hints and sync each see a single change.
    static func choose(
        _ choice: KeyboardPresetChoice,
        in keyboard: SettingsSlice<KeyboardSettings>,
        window: NSWindow?
    ) async -> Bool {
        guard let next = choice.settings(isSystemHotkey: { SystemHotkeyChecker.shared.isReserved($0) }) else {
            return true
        }
        let current = keyboard.value
        if KeyboardPresetChoice.asksBeforeReplacing(current, with: next) {
            let confirmed = await KeyboardPresetConfirmation.confirmReplacing(
                customizedCount: current.customizedCount,
                with: displayName(of: choice),
                window: window
            )
            guard confirmed else { return false }
        }
        keyboard.value = next
        return true
    }

    private static func displayName(of choice: KeyboardPresetChoice) -> String {
        switch choice {
        case .preset(let preset): preset.name
        case .keepCurrent, .tablePro: "TablePro"
        }
    }
}

@MainActor
enum KeyboardPresetConfirmation {
    static func confirmReplacing(customizedCount: Int, with name: String, window: NSWindow?) async -> Bool {
        let message = customizedCount == 1
            ? String(localized: "The shortcut you changed is replaced.")
            : String(format: String(localized: "The %lld shortcuts you changed are replaced."), customizedCount)
        return await AlertHelper.confirmDestructive(
            title: String(format: String(localized: "Use %@ Shortcuts?"), name),
            message: message,
            confirmButton: String(localized: "Replace"),
            window: window
        )
    }
}
