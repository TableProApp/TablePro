//
//  MaterializedViewRefreshAlert.swift
//  TablePro
//

import AppKit

/// An informational alert, not a destructive one: the user chose this command on purpose and a
/// refresh loses nothing, so the confirming button keeps Return, which the HIG reserves taking away
/// for an action people did not deliberately choose.
@MainActor
internal enum MaterializedViewRefreshAlert {
    private static let accessoryWidth: CGFloat = 300
    private static let descriptionIndent: CGFloat = 20

    /// - Parameter completion: nil when cancelled, otherwise whether to refresh concurrently.
    internal static func present(
        prompt: MaterializedViewRefreshPrompt,
        window: NSWindow?,
        completion: @escaping @MainActor (Bool?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        alert.alertStyle = .informational
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        AlertHelper.addCancelButton(to: alert, title: prompt.cancelButtonTitle)

        let checkbox = prompt.showsConcurrentOption ? concurrentCheckbox(prompt: prompt) : nil
        if let checkbox {
            alert.accessoryView = accessoryView(checkbox: checkbox, description: prompt.concurrentOptionDescription)
            alert.layout()
        }

        AlertHelper.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(prompt.refreshesConcurrently(checkboxIsOn: checkbox?.state == .on))
        }
    }

    private static func concurrentCheckbox(prompt: MaterializedViewRefreshPrompt) -> NSButton {
        let button = NSButton(checkboxWithTitle: prompt.concurrentOptionTitle, target: nil, action: nil)
        button.state = .off
        button.isEnabled = prompt.isConcurrentOptionEnabled
        button.setAccessibilityIdentifier("refresh-materialized-view-concurrently")
        if !prompt.isConcurrentOptionEnabled {
            button.toolTip = prompt.concurrentOptionDescription
            button.setAccessibilityHelp(prompt.concurrentOptionDescription)
        }
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
