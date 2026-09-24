//
//  TransferResultAlert.swift
//  TablePro
//

import AppKit
import TableProPluginKit
import UniformTypeIdentifiers

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

    /// An export that finished with something to report says so here, the way an import already
    /// does. The suppression checkbox is offered only on a clean run: the alert the user turned
    /// off is the routine one, and hiding a warning behind that switch loses it for good.
    ///
    /// `notes` are what the export wrote and `warnings` are what went wrong with it, so only the
    /// second decides the title, the icon and whether the checkbox appears. Both go in the body,
    /// notes first, which is the order `presentTransferSuccess` and `presentImportSuccess` already
    /// put their own summaries in.
    internal static func presentExportSuccess(
        warnings: [String],
        notes: [String] = [],
        window: NSWindow?,
        completion: @escaping @MainActor (ExportChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = warnings.isEmpty
            ? String(localized: "Export completed")
            : String(localized: "Export completed with warnings")
        alert.alertStyle = warnings.isEmpty ? .informational : .warning
        alert.informativeText = (notes + warnings).joined(separator: "\n\n")
        alert.addButton(withTitle: String(localized: "Open in Finder"))
        /// `NSAlert` binds Escape by matching a button's title against "Cancel", which stops
        /// matching in every localized build and never matched "Done" at all. Without this the
        /// alert answers no key but Return, which opens Finder.
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))
        alert.showsSuppressionButton = warnings.isEmpty
        alert.suppressionButton?.title = String(localized: "Do not show this again")

        let deliver: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            if alert.suppressionButton?.state == .on {
                AppStorageEnvironment.shared.defaults.set(true, forKey: exportSuppressionKey)
            }
            completion(response == .alertFirstButtonReturn ? .openFolder : .close)
        }

        AlertHelper.present(alert, in: window, completion: deliver)
    }

    /// A transfer writes into another connection and leaves nothing on disk, so there is no folder
    /// to open and no file to name. It still has to say how much moved and where, which it did not:
    /// the sheet used to close on success and report nothing at all.
    internal static func presentTransferSuccess(
        tableCount: Int,
        rowCount: Int,
        destinationName: String,
        warnings: [String],
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = warnings.isEmpty
            ? String(localized: "Transfer completed")
            : String(localized: "Transfer completed with warnings")
        alert.alertStyle = warnings.isEmpty ? .informational : .warning
        alert.informativeText = ([transferSummary(
            tableCount: tableCount, rowCount: rowCount, destinationName: destinationName
        )] + warnings).joined(separator: "\n\n")
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))
        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    private static func transferSummary(
        tableCount: Int,
        rowCount: Int,
        destinationName: String
    ) -> String {
        let template = tableCount == 1
            ? String(localized: "%1$lld rows from 1 table written to %2$@.")
            : String(localized: "%1$lld rows from %3$lld tables written to %2$@.")
        return String(format: template, Int64(rowCount), destinationName, Int64(tableCount))
    }

    /// A stopped import leaves whatever it already ran committed, and used to close its progress
    /// sheet without saying so. Stopping looked the same as importing nothing.
    internal static func presentImportCancelled(
        executedStatements: Int,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Import stopped")
        alert.alertStyle = .warning
        let template = executedStatements == 1
            ? String(localized: "%lld statement had already run and stays committed.")
            : String(localized: "%lld statements had already run and stay committed.")
        alert.informativeText = String(format: template, Int64(executedStatements))
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))
        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    internal static func presentImportSuccess(
        result: PluginImportResult?,
        window: NSWindow?,
        sourceFileName: String = "",
        targetTable: String? = nil,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        let skipped = result?.skippedStatements ?? 0
        alert.messageText = skipped > 0
            ? String(localized: "Import completed with errors")
            : String(localized: "Import completed")
        alert.alertStyle = skipped > 0 ? .warning : .informational
        alert.informativeText = importSummary(result)
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))

        let errors = result?.errors ?? []
        if !errors.isEmpty {
            /// The alert shows the first few, which is enough to recognise the shape of the
            /// problem. Anything past that belongs in a file the user can sort and search.
            alert.addButton(withTitle: String(localized: "Save Report…"))
            alert.accessoryView = TransferReportView(report: failureReport(for: errors))
            alert.layout()
        }

        AlertHelper.present(alert, in: window) { response in
            guard !errors.isEmpty, response == .alertSecondButtonReturn else {
                completion()
                return
            }
            saveErrorReport(
                errors: errors,
                totalSkipped: skipped,
                sourceFileName: sourceFileName,
                targetTable: targetTable,
                window: window,
                completion: completion
            )
        }
    }

    @MainActor
    private static func saveErrorReport(
        errors: [PluginImportResult.ImportStatementError],
        totalSkipped: Int,
        sourceFileName: String,
        targetTable: String?,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = ImportErrorReport.defaultFileName(forSource: sourceFileName)
        panel.title = String(localized: "Save Import Errors")

        let handler: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            defer { completion() }
            guard response == .OK, let url = panel.url else { return }
            let csv = ImportErrorReport.makeCSV(
                sourceFileName: sourceFileName,
                targetTable: targetTable,
                errors: errors,
                totalSkipped: totalSkipped
            )
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }

        guard let window else {
            handler(panel.runModal())
            return
        }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { handler(response) }
        }
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
        alert.informativeText = importFailureText(for: error)

        if let pluginError = error as? PluginImportError,
           case .statementFailed(let statement, _, _) = pluginError {
            alert.accessoryView = TransferReportView(
                shown: statement,
                copied: failureReport(for: error) ?? statement
            )
            alert.layout()
        }

        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    /// The text of a failed import's alert: the line it stopped at and the first of the database's errors.
    internal static func importFailureText(for error: (any Error)?) -> String {
        guard let pluginError = error as? PluginImportError,
              case .statementFailed(_, let line, let underlyingError) = pluginError else {
            return RevealedText(error?.localizedDescription ?? String(localized: "Unknown error")).plainText
        }
        return RevealedText(String(
            format: String(localized: "Failed at line %lld. %@"),
            Int64(line),
            shownErrors(underlyingError.localizedDescription)
        )).plainText
    }

    /// The most of a failure's errors an alert's text holds, in lines and in UTF-16 units. A SQL Server batch raises
    /// one error per statement that failed and the driver keeps up to 1,000, one line each, while an alert grows to fit
    /// its text: measured, 1,000 lines made one 54,135 points tall, its Done button far below the screen, and 1,000
    /// units on one line keep it at 423 points. Copy Details carries all of it.
    internal static let shownErrorLineLimit = 5
    internal static let shownErrorLengthLimit = 1_000

    /// The start of `description` the alert has room for, and where the rest is.
    internal static func shownErrors(_ description: String) -> String {
        let lines = description.components(separatedBy: "\n")
        let firstLines = lines.prefix(shownErrorLineLimit).joined(separator: "\n")
        let shown = cut(firstLines, toUnits: shownErrorLengthLimit) ?? firstLines
        guard shown != description else { return description }
        return shown + "\n" + String(localized: "Copy Details copies the rest.")
    }

    /// `text` cut to `limit` UTF-16 units on a character boundary, with an ellipsis saying there is more, or nil when
    /// it already fits.
    internal static func cut(_ text: String, toUnits limit: Int) -> String? {
        let source = text as NSString
        guard source.length > limit else { return nil }
        let end = source.rangeOfComposedCharacterSequence(at: limit).location
        return source.substring(to: end) + "\u{2026}"
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

    /// The most of a report the box shows. A failed statement can be a whole SQL Server batch, and the text view lays
    /// out a paragraph whole on the main thread: measured, a 15 million unit batch holding one 5 million unit line
    /// blocked it for 67 seconds and took 2.7 GB, where the first 10,000 units took 0.1 seconds. Copy Details still
    /// carries every unit.
    internal static let shownLengthLimit = 10_000

    /// `text` cut to `shownLengthLimit` on a character boundary, with an ellipsis saying there is more.
    internal static func shownText(_ text: String) -> String {
        TransferResultAlert.cut(text, toUnits: shownLengthLimit) ?? text
    }

    private let report: String

    internal convenience init(report: String) {
        self.init(shown: report, copied: report)
    }

    internal init(shown: String, copied: String) {
        report = copied
        let button = NSButton(title: String(localized: "Copy Details"), target: nil, action: nil)
        button.bezelStyle = .push
        button.sizeToFit()
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: Self.textHeight + Self.spacing + button.frame.height
        ))

        let scroll = TransferResultAlert.scrollingText(RevealedText(Self.shownText(shown)).plainText)
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
