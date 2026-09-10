//
//  TableOperationAlert.swift
//  TablePro
//

import AppKit

@MainActor
internal enum TableOperationAlert {
    private static let accessoryWidth: CGFloat = 280
    private static let descriptionIndent: CGFloat = 20

    internal static func present(
        prompt: TableOperationPrompt,
        window: NSWindow?,
        completion: @escaping @MainActor (TableOperationOptions?) -> Void
    ) {
        let ignoreForeignKeys = checkbox(
            title: prompt.ignoreForeignKeysTitle,
            isEnabled: prompt.isIgnoreForeignKeysEnabled
        )
        let cascade = checkbox(title: prompt.cascadeTitle, isEnabled: prompt.isCascadeEnabled)

        let alert = NSAlert()
        alert.messageText = prompt.messageText
        alert.informativeText = prompt.informativeText
        alert.alertStyle = .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: prompt.confirmButtonTitle,
            cancelButton: prompt.cancelButtonTitle
        )
        alert.accessoryView = accessoryView(
            prompt: prompt,
            ignoreForeignKeys: ignoreForeignKeys,
            cascade: cascade
        )
        alert.layout()

        AlertHelper.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            completion(
                prompt.options(
                    ignoreForeignKeys: ignoreForeignKeys.state == .on,
                    cascade: cascade.state == .on
                )
            )
        }
    }

    private static func checkbox(title: String, isEnabled: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = .off
        button.isEnabled = isEnabled
        return button
    }

    private static func accessoryView(
        prompt: TableOperationPrompt,
        ignoreForeignKeys: NSButton,
        cascade: NSButton
    ) -> NSView {
        var rows: [NSView] = [ignoreForeignKeys]
        if let description = prompt.ignoreForeignKeysDescription {
            rows.append(indented(descriptionLabel(description)))
        }
        rows.append(cascade)
        rows.append(indented(descriptionLabel(prompt.cascadeDescription)))

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

    private static func descriptionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = accessoryWidth - descriptionIndent
        return label
    }

    private static func indented(_ view: NSView) -> NSView {
        let container = NSStackView(views: [view])
        container.orientation = .horizontal
        container.alignment = .top
        container.edgeInsets = NSEdgeInsets(top: 0, left: descriptionIndent, bottom: 0, right: 0)
        return container
    }
}
