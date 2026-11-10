import AppKit

extension NSTableView {
    // NSTableView moves the selection itself but passes Return and Delete up as plain key events, so an
    // insertNewline(_:) or deleteBackward(_:) on the table or above it never runs unless they go through here.
    func interpretCommandKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .shift, .option, .control]),
              let command = Self.command(for: event.specialKey),
              answersFromHereUp(command) else { return false }
        interpretKeyEvents([event])
        return true
    }

    private static func command(for key: NSEvent.SpecialKey?) -> Selector? {
        switch key {
        case .carriageReturn?, .newline?, .enter?:
            return #selector(NSResponder.insertNewline(_:))
        case .delete?:
            return #selector(NSResponder.deleteBackward(_:))
        case .deleteForward?:
            return #selector(NSResponder.deleteForward(_:))
        default:
            return nil
        }
    }

    // A key nobody answers keeps travelling up as a key event, so a sheet's default button still gets Return.
    private func answersFromHereUp(_ command: Selector) -> Bool {
        var responder: NSResponder? = self
        while let current = responder {
            if current.responds(to: command) { return true }
            responder = current.nextResponder
        }
        return false
    }
}
