//
//  UserTypeDropAlert.swift
//  TablePro
//

import AppKit

struct UserTypeDropPrompt: Equatable {
    let qualifiedName: String
    let offersCascade: Bool

    var messageText: String {
        String(format: String(localized: "Drop type “%@”?"), qualifiedName)
    }

    var informativeText: String {
        offersCascade
            ? String(localized: "This cannot be undone. Without Cascade, the drop fails while a column, function or other type still uses it.")
            : String(localized: "This cannot be undone. The drop fails while a column or other object still uses it.")
    }

    var cascadeTitle: String { String(localized: "Cascade") }

    var cascadeDescription: String {
        String(localized: "Also drop the columns, functions and other objects that use this type")
    }
}

/// The type drop's one confirmation. It asks the Cascade question the gate cannot, so the run that
/// follows tells the gate it was confirmed rather than asking twice.
@MainActor
enum UserTypeDropAlert {
    private static let accessoryWidth: CGFloat = 300
    private static let descriptionIndent: CGFloat = 20

    /// - Parameter completion: nil when cancelled, otherwise whether to cascade.
    static func present(
        prompt: UserTypeDropPrompt,
        window: NSWindow?,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        alert.alertStyle = .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: String(localized: "Drop"),
            cancelButton: String(localized: "Cancel")
        )

        let cascade = prompt.offersCascade ? cascadeCheckbox(prompt) : nil
        if let cascade {
            alert.accessoryView = accessoryView(checkbox: cascade, description: prompt.cascadeDescription)
            alert.layout()
        }

        AlertHelper.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(cascade?.state == .on)
        }
    }

    private static func cascadeCheckbox(_ prompt: UserTypeDropPrompt) -> NSButton {
        let button = NSButton(checkboxWithTitle: prompt.cascadeTitle, target: nil, action: nil)
        button.state = .off
        button.setAccessibilityIdentifier("drop-type-cascade")
        return button
    }

    private static func accessoryView(checkbox: NSButton, description: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: description)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = accessoryWidth - descriptionIndent

        let indented = NSStackView(views: [label])
        indented.orientation = .horizontal
        indented.alignment = .top
        indented.edgeInsets = NSEdgeInsets(top: 0, left: descriptionIndent, bottom: 0, right: 0)

        let rows: [NSView] = [checkbox, indented]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            row.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        return stack
    }
}
