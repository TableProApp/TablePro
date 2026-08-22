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
            alert.accessoryView = TransferReportView(report: failureReport(for: errors))
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
            alert.accessoryView = TransferReportView(
                shown: statement,
                copied: failureReport(for: error) ?? statement
            )
            alert.layout()
        } else {
            alert.informativeText = error?.localizedDescription ?? String(localized: "Unknown error")
        }

        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    /// The report a failed import puts in its accessory, so the line, the reason and the failing
    /// statement can be selected and copied together. Returns nil for an error that carries no
    /// statement, where the alert's own text already says everything there is to say.
    internal static func failureReport(for error: (any Error)?) -> String? {
        guard let pluginError = error as? PluginImportError,
              case .statementFailed(let statement, let line, let underlyingError) = pluginError else {
            return nil
        }
        return failureReport(for: [
            PluginImportResult.ImportStatementError(
                statement: statement,
                line: line,
                errorMessage: underlyingError.localizedDescription
            )
        ])
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
    fileprivate static func scrollingText(_ text: String) -> NSScrollView {
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

/// The failure report is what a user has to act on, so it is selectable text with a copy button
/// of its own. An `NSAlert` button cannot serve here because any of them dismisses the alert, so
/// the control belongs to the accessory view instead.
///
/// What is copied can say more than what is shown. A single failure shows the statement, because
/// the alert's own text already names the line and the reason, but copying carries all three so
/// the pasted text stands on its own.
internal final class TransferReportView: NSView {
    private static let width: CGFloat = 380
    private static let textHeight: CGFloat = 140
    private static let spacing: CGFloat = 8

    private let report: String

    internal convenience init(report: String) {
        self.init(shown: report, copied: report)
    }

    internal init(shown: String, copied: String) {
        report = copied
        let button = NSButton(title: String(localized: "Copy Details"), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.sizeToFit()
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: Self.textHeight + Self.spacing + button.frame.height
        ))

        let scroll = TransferResultAlert.scrollingText(shown)
        scroll.frame = NSRect(
            x: 0,
            y: button.frame.height + Self.spacing,
            width: Self.width,
            height: Self.textHeight
        )
        scroll.autoresizingMask = [.width]
        addSubview(scroll)

        button.target = self
        button.action = #selector(copyReport)
        button.frame.origin = NSPoint(x: Self.width - button.frame.width, y: 0)
        button.autoresizingMask = [.minXMargin]
        addSubview(button)
    }

    internal required init?(coder: NSCoder) {
        report = ""
        super.init(coder: coder)
    }

    @objc
    internal func copyReport() {
        ClipboardService.shared.writeText(report)
    }
}
