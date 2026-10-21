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

    /// A stopped import used to close its progress sheet without saying what it left behind, so stopping looked the
    /// same as importing nothing.
    internal static func presentImportCancelled(
        executedStatements: Int,
        transaction: ImportTransactionOutcome,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Import stopped")
        alert.alertStyle = .warning
        alert.informativeText = importCancelledText(executedStatements: executedStatements, transaction: transaction)
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))
        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    internal static func importCancelledText(executedStatements: Int, transaction: ImportTransactionOutcome) -> String {
        let isOne = executedStatements == 1
        let template: String
        switch transaction {
        case .rolledBack:
            template = isOne
                ? String(localized: "%lld statement had already run and was rolled back.")
                : String(localized: "%lld statements had already run and were rolled back.")
        case .committedBeforeRollback:
            template = isOne
                ? String(localized: """
                    %lld statement had already run and was kept, because a statement in the file, such as COMMIT, \
                    CREATE, ALTER or DROP, committed the import's transaction as it ran.
                    """)
                : String(localized: """
                    %lld statements had already run. Some were kept, because a statement in the file, such as \
                    COMMIT, CREATE, ALTER or DROP, committed the import's transaction as it ran.
                    """)
        case .untracked, .committed, .endedByServer, .endedByFile:
            template = isOne
                ? String(localized: "%lld statement had already run and stays committed.")
                : String(localized: "%lld statements had already run and stay committed.")
        }
        return String(format: template, Int64(executedStatements))
    }

    internal static func presentImportSuccess(
        result: PluginImportResult?,
        rowTally: ImportRowTally? = nil,
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
        alert.informativeText = importSummary(result, rowTally: rowTally)
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

    /// A run of several files says what became of each, with its row count, and whether a failure took back the files
    /// before it. Copy Details carries every skipped row's error as well.
    internal static func presentBatchImportResult(
        _ report: RowImportBatchReport,
        window: NSWindow?,
        completion: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        switch report.ending {
        case .completed:
            alert.messageText = report.hasFailures
                ? String(localized: "Import completed with errors")
                : String(localized: "Import completed")
            alert.alertStyle = report.hasFailures ? .warning : .informational
        case .failed:
            alert.messageText = String(localized: "Import failed")
            alert.alertStyle = .critical
        case .stopped:
            alert.messageText = String(localized: "Import stopped")
            alert.alertStyle = .warning
        }
        alert.informativeText = batchImportSummary(report)
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Done"))
        let lines = batchImportLines(report)
        alert.accessoryView = TransferReportView(
            shown: lines.joined(separator: "\n"),
            copied: ([lines.joined(separator: "\n")] + batchImportErrors(report)).joined(separator: "\n\n")
        )
        alert.layout()
        AlertHelper.present(alert, in: window) { _ in completion() }
    }

    internal static func batchImportSummary(_ report: RowImportBatchReport) -> String {
        let seconds = String(format: "%.2f", report.executionTime)
        switch report.ending {
        case .completed:
            return String(
                format: String(localized: "%1$lld rows from %2$lld files in %3$@ seconds."),
                Int64(report.importedRowCount),
                Int64(report.files.count),
                seconds
            )
        case .failed(let index):
            let failure = importFailureText(for: report.failure)
            let template = report.rowsKept
                ? String(localized: "%1$@ failed, and the files imported before it were kept. %2$@")
                : String(localized: "%1$@ failed, so every file was rolled back. %2$@")
            return String(format: template, report.files[index].sourceName, failure)
        case .stopped(let index):
            let template = report.rowsKept
                ? String(localized: "Stopped at %@. The files imported before it were kept.")
                : String(localized: "Stopped at %@. Every file was rolled back.")
            return String(format: template, report.files[index].sourceName)
        }
    }

    /// One line per file: where its rows went and how many, or why none did.
    internal static func batchImportLines(_ report: RowImportBatchReport) -> [String] {
        zip(report.files, report.outcomes).map { file, outcome in
            let status: String
            switch outcome {
            case .imported(let result):
                status = importedRows(result, kept: report.rowsKept)
            case .failed(let error, let rows):
                status = [importFailureText(for: error), rowsBefore(rows, kept: report.rowsKept)]
                    .compactMap { $0 }
                    .joined(separator: " ")
            case .stopped(let rows):
                status = [String(localized: "Stopped."), rowsBefore(rows, kept: report.rowsKept)]
                    .compactMap { $0 }
                    .joined(separator: " ")
            case .notRun:
                status = String(localized: "not imported")
            }
            return String(format: String(localized: "%1$@ to %2$@: %3$@"), file.sourceName, file.targetTable, status)
        }
    }

    /// A file that stopped part way can already have written batches, which stay or go with the run.
    private static func rowsBefore(_ rows: Int, kept: Bool) -> String? {
        guard rows > 0 else { return nil }
        if rows == 1 {
            return kept
                ? String(localized: "1 row before it was kept.")
                : String(localized: "1 row before it was rolled back.")
        }
        let template = kept
            ? String(localized: "%lld rows before it were kept.")
            : String(localized: "%lld rows before it were rolled back.")
        return String(format: template, Int64(rows))
    }

    private static func importedRows(_ result: PluginImportResult, kept: Bool) -> String {
        let rows = result.executedStatements
        var text = rows == 1
            ? String(localized: "1 row")
            : String(format: String(localized: "%lld rows"), Int64(rows))
        if result.skippedStatements > 0 {
            text += ", " + String(format: String(localized: "%lld failed"), Int64(result.skippedStatements))
        }
        if !kept {
            text += ", " + String(localized: "rolled back")
        }
        return text
    }

    /// Everything the lines cut short: each skipped row's error, and a failed file's whole error and statement.
    private static func batchImportErrors(_ report: RowImportBatchReport) -> [String] {
        zip(report.files, report.outcomes).compactMap { file, outcome in
            switch outcome {
            case .imported(let result) where !result.errors.isEmpty:
                return "\(file.sourceName)\n\(failureReport(for: result.errors))"
            case .failed(let error, _):
                return "\(file.sourceName)\n\(failureReport(for: error) ?? error.localizedDescription)"
            case .imported, .stopped, .notRun:
                return nil
            }
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

    internal static func importSummary(_ result: PluginImportResult?, rowTally: ImportRowTally? = nil) -> String {
        guard let result else { return "" }
        let seconds = String(
            format: String(localized: "%@ seconds"),
            String(format: "%.2f", result.executionTime)
        )
        if let rowTally {
            return (rowTally.summaryLines(failed: result.skippedStatements) + [seconds]).joined(separator: "\n")
        }
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
        return "\(counts)\n\(seconds)"
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

        let scroll = AlertHelper.scrollingTextAccessory(RevealedText(Self.shownText(shown)).plainText)
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
