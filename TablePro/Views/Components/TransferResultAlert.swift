//
//  TransferResultAlert.swift
//  TablePro
//

import AppKit
import TableProPluginKit

/// Import and export results were three bespoke views with fixed widths and hand-picked green,
/// yellow and red badges. `NSAlert` supplies the icon from its style, sizes itself to its content,
/// and is the only one of the two that can carry a real suppression checkbox.
@MainActor
internal enum TransferResultAlert {
    internal static let exportSuppressionKey = "hideExportSuccessDialog"

    internal enum ExportChoice {
        case openFolder
        case close
    }

    internal static func presentExportSuccess(
        window: NSWindow?,
        completion: @escaping @MainActor (ExportChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Export completed")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Open in Finder"))
        alert.addButton(withTitle: String(localized: "Done"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Do not show this again")

        let deliver: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on {
                AppStorageEnvironment.shared.defaults.set(true, forKey: exportSuppressionKey)
            }
            completion(response == .alertFirstButtonReturn ? .openFolder : .close)
        }

        AlertHelper.present(alert, in: window, completion: deliver)
    }

    internal static func presentImportSuccess(
        result: PluginImportResult?,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        let skipped = result?.skippedStatements ?? 0
        alert.messageText = skipped > 0
            ? String(localized: "Import completed with errors")
            : String(localized: "Import completed")
        alert.alertStyle = skipped > 0 ? .warning : .informational
        alert.informativeText = importSummary(result)
        alert.addButton(withTitle: String(localized: "Done"))

        if let errors = result?.errors, !errors.isEmpty {
            alert.accessoryView = scrollingText(failureReport(for: errors))
            alert.layout()
        }

        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    internal static func presentImportFailure(
        error: (any Error)?,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Import failed")
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Done"))

        if let pluginError = error as? PluginImportError,
           case .statementFailed(let statement, let line, let underlyingError) = pluginError {
            alert.informativeText = String(
                format: String(localized: "Failed at line %lld. %@"),
                Int64(line),
                underlyingError.localizedDescription
            )
            alert.accessoryView = scrollingText(statement)
            alert.layout()
        } else {
            alert.informativeText = error?.localizedDescription ?? String(localized: "Unknown error")
        }

        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    /// A row import names its failing entry `row 12`, which the line number already says, so only
    /// a statement that carries something the line number does not is worth repeating.
    internal static func failureReport(for failures: [PluginImportResult.ImportStatementError]) -> String {
        failures.map { failure in
            let heading = String(
                format: String(localized: "Line %1$lld: %2$@"),
                Int64(failure.line),
                failure.errorMessage
            )
            let statement = failure.statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty, statement != "row \(failure.line)" else { return heading }
            return "\(heading)\n\(statement)"
        }
        .joined(separator: "\n\n")
    }

    private static func importSummary(_ result: PluginImportResult?) -> String {
        guard let result else { return "" }
        let counts = result.skippedStatements > 0
            ? String(
                format: String(localized: "%1$lld statements executed, %2$lld failed"),
                Int64(result.executedStatements),
                Int64(result.skippedStatements)
            )
            : String(
                format: String(localized: "%lld statements executed"),
                Int64(result.executedStatements)
            )
        let seconds = String(
            format: String(localized: "%@ seconds"),
            String(format: "%.2f", result.executionTime)
        )
        return "\(counts)\n\(seconds)"
    }

    /// A text view laid inside a scroll view by hand has to be told it may grow and that its text
    /// container tracks its width. Left at its default zero-sized container it lays out no text at
    /// all, so the accessory reads as an empty box.
    private static func scrollingText(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 140))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scroll.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        scroll.documentView = textView
        return scroll
    }
}
