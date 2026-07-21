//
//  PromptKeyboardInteractiveProvider.swift
//  TablePro
//

import AppKit
import Foundation

/// Prompts the user for keyboard-interactive responses via a modal NSAlert.
///
/// The SSH server's own prompt text is shown verbatim, one field per prompt, with each field
/// masked or visible per the prompt's echo flag. The call blocks the SSH worker thread until the
/// user answers. `runModal()` is intentional: the caller may already be on the main thread via
/// `DispatchQueue.main.sync`, where `beginSheetModal` plus a semaphore would deadlock.
internal final class PromptKeyboardInteractiveProvider: KeyboardInteractivePromptProvider, @unchecked Sendable {
    func provideResponses(for challenge: KeyboardInteractiveChallenge, attempt: Int) throws -> [String] {
        let responses = Thread.isMainThread
            ? showAlert(for: challenge, attempt: attempt)
            : DispatchQueue.main.sync { showAlert(for: challenge, attempt: attempt) }

        guard let responses else {
            throw SSHTunnelError.authenticationFailed(reason: .cancelled)
        }
        return responses
    }

    private func showAlert(for challenge: KeyboardInteractiveChallenge, attempt: Int) -> [String]? {
        let alert = NSAlert()
        alert.messageText = attempt == 0
            ? String(localized: "SSH Verification Required")
            : String(localized: "SSH Verification Rejected")
        alert.informativeText = informativeText(for: challenge, attempt: attempt)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        var fields: [NSTextField] = []
        for prompt in challenge.prompts {
            let caption = NSTextField(labelWithString: prompt.text.isEmpty
                ? String(localized: "Response")
                : prompt.text)
            caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            caption.textColor = .secondaryLabelColor

            let field: NSTextField = prompt.isSecure ? NSSecureTextField() : NSTextField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true

            stack.addArrangedSubview(caption)
            stack.addArrangedSubview(field)
            fields.append(field)
        }

        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.layout()
        alert.window.initialFirstResponder = fields.first

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.map(\.stringValue)
    }

    private func informativeText(for challenge: KeyboardInteractiveChallenge, attempt: Int) -> String {
        if attempt > 0 {
            return String(localized: "The previous response wasn't accepted. Try again.")
        }
        if !challenge.instruction.isEmpty {
            return challenge.instruction
        }
        if !challenge.name.isEmpty {
            return challenge.name
        }
        return String(localized: "The SSH server is asking for additional verification.")
    }
}
