//
//  DataFileStatusBar.swift
//  TablePro
//

import SwiftUI
import TableProTabularIO

struct DataFileStatusBar: View {
    @ObservedObject var controller: DataFileController
    @State private var showsSelectionSummaryPopover = false

    var body: some View {
        HStack(spacing: 14) {
            if controller.loadState == .loaded {
                rowSummary
                Text("^[\(controller.columnNames.count) column](inflect: true)")
                if !controller.selectedRowIndices.isEmpty {
                    Text("\(controller.selectedRowIndices.count) selected")
                }
                SelectionSummaryReadout(
                    state: controller.selectionSummary,
                    scopeNote: selectionSummaryScopeNote,
                    isPopoverPresented: $showsSelectionSummaryPopover
                )
                if controller.raggedRowCount > 0 {
                    Text(DataFileCountPhrase.raggedRows(controller.raggedRowCount))
                        .help(String(localized: "Those rows have more or fewer fields than the first row. Missing fields read as empty."))
                }
                if controller.undecodableLineCount > 0, let dialect = controller.dialect {
                    Text(DataFileCountPhrase.undecodableLines(controller.undecodableLineCount))
                        .help(String(
                            format: String(localized: "Bytes on those lines are not valid %@ and show as \u{FFFD}. Pick another encoding in File Properties."),
                            dialect.encoding.displayName
                        ))
                        .accessibilityIdentifier("data-file-undecodable-lines")
                }
            }
            if let message = controller.statusMessage {
                Text(message)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if let activity = controller.activity, activity.isVisible {
                activityView(activity)
            }
            if let dialect = controller.dialect, controller.kind?.format == .delimited {
                Text(DataFileDialectDescription.summary(dialect))
                    .accessibilityLabel(String(localized: "File format"))
                    .accessibilityValue(DataFileDialectDescription.summary(dialect))
                    .accessibilityIdentifier("data-file-format")
            }
            if controller.pageCount > 1 {
                pageControls
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .statusBarChrome()
    }

    private var selectionSummaryScopeNote: String? {
        guard controller.pageCount > 1 else { return nil }
        return String(localized: "Covers this page only. Column Statistics covers the whole file.")
    }

    @ViewBuilder
    private var rowSummary: some View {
        Group {
            if controller.visibleRowCount == controller.totalRowCount {
                Text("^[\(controller.totalRowCount) row](inflect: true)")
            } else {
                Text("\(controller.visibleRowCount) of ^[\(controller.totalRowCount) row](inflect: true)")
            }
        }
        .accessibilityIdentifier("data-file-row-count")
    }

    private func activityView(_ activity: DataFileActivity) -> some View {
        HStack(spacing: 6) {
            ProgressView(value: activity.fraction)
                .progressViewStyle(.linear)
                .frame(width: 90)
                .accessibilityLabel(activity.title)
            Text(activity.title)
            Button(String(localized: "Cancel"), systemImage: "xmark.circle.fill") {
                controller.cancelActivity()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(String(localized: "Cancel"))
        }
    }

    private var pageControls: some View {
        HStack(spacing: 6) {
            Button(String(localized: "Previous page"), systemImage: "chevron.left") {
                controller.goToPage(offsetBy: -1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(controller.pageOffset == 0)

            Text("Page \(currentPage) of \(controller.pageCount)")

            Button(String(localized: "Next page"), systemImage: "chevron.right") {
                controller.goToPage(offsetBy: 1)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .disabled(currentPage >= controller.pageCount)
        }
    }

    private var currentPage: Int {
        controller.pageSize > 0 ? (controller.pageOffset / controller.pageSize) + 1 : 1
    }
}

enum DataFileDialectDescription {
    static func summary(_ dialect: DelimitedDialect) -> String {
        [delimiterName(dialect.delimiter), dialect.encoding.displayName, lineEndingName(dialect.lineEnding)]
            .joined(separator: ", ")
    }

    static func delimiterName(_ delimiter: UInt8) -> String {
        switch delimiter {
        case DelimitedDialect.comma: return String(localized: "Comma")
        case DelimitedDialect.tab: return String(localized: "Tab")
        case DelimitedDialect.semicolon: return String(localized: "Semicolon")
        case DelimitedDialect.pipe: return String(localized: "Pipe")
        default: return String(UnicodeScalar(delimiter))
        }
    }

    static func lineEndingName(_ lineEnding: DelimitedDialect.LineEnding) -> String {
        switch lineEnding {
        case .lf: return "LF"
        case .crlf: return "CRLF"
        case .cr: return "CR"
        }
    }
}
