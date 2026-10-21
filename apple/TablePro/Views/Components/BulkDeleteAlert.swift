import AppKit

@MainActor
internal enum BulkDeleteAlert {
    enum Choice: Equatable {
        case delete
        case cancel
        case showRows(BulkDeleteConfirmation.Line)
    }

    private static let accessoryWidth: CGFloat = 320
    // Clear of the 1000-based codes NSAlert gives its own buttons.
    private static let showRowsCodeBase = 5_000

    static func present(_ confirmation: BulkDeleteConfirmation, window: NSWindow?) async -> Choice {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.alertStyle = .warning
        AlertHelper.addConfirmAndCancel(
            to: alert,
            confirmButton: confirmation.confirmButtonTitle,
            cancelButton: String(localized: "Cancel")
        )

        let lines = confirmation.visibleLines
        let handler = ShowRowsHandler(alert: alert, codeBase: showRowsCodeBase)
        if !lines.isEmpty {
            alert.accessoryView = accessoryView(
                lines: lines,
                hiddenLineCount: confirmation.hiddenLineCount,
                handler: handler
            )
            alert.layout()
        }

        let response = await AlertHelper.response(to: alert, in: window)
        return withExtendedLifetime(handler) {
            if response == .alertFirstButtonReturn { return .delete }
            let index = response.rawValue - showRowsCodeBase
            guard lines.indices.contains(index) else { return .cancel }
            return .showRows(lines[index])
        }
    }

    private static func accessoryView(
        lines: [BulkDeleteConfirmation.Line],
        hiddenLineCount: Int,
        handler: ShowRowsHandler
    ) -> NSView {
        var rows: [NSView] = lines.enumerated().map { index, line in
            row(for: line, tag: index, handler: handler)
        }
        if hiddenLineCount > 0 {
            rows.append(label(String(format: String(localized: "And %lld more"), hiddenLineCount)))
        }

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

    private static func row(for line: BulkDeleteConfirmation.Line, tag: Int, handler: ShowRowsHandler) -> NSView {
        let text = label(line.text)
        guard line.filterCondition != nil else { return text }

        let button = NSButton(title: String(localized: "Show"), target: handler, action: #selector(ShowRowsHandler.showRows(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.tag = tag
        button.setAccessibilityLabel(String(format: String(localized: "Show rows in %@"), line.table))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        text.preferredMaxLayoutWidth = accessoryWidth - button.fittingSize.width - 8

        let row = NSStackView(views: [text, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private static func label(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.preferredMaxLayoutWidth = accessoryWidth
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }
}

@MainActor
private final class ShowRowsHandler: NSObject {
    private weak var alert: NSAlert?
    private let codeBase: Int

    init(alert: NSAlert, codeBase: Int) {
        self.alert = alert
        self.codeBase = codeBase
    }

    // Ends the alert the way its own buttons do, as a sheet or as an application-modal run.
    @objc func showRows(_ sender: NSButton) {
        guard let window = alert?.window else { return }
        let code = NSApplication.ModalResponse(rawValue: codeBase + sender.tag)
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: code)
        } else {
            NSApp.stopModal(withCode: code)
        }
    }
}
