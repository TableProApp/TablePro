//
//  TransferResult.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

internal struct TransferResult: Sendable {
    internal enum Outcome: Equatable, Sendable {
        case succeeded
        case succeededWithIssues
        case stopped
        case failed
    }

    internal struct Details: Hashable, Sendable {
        internal let shown: String
        internal let copied: String
    }

    internal struct ErrorReport: Sendable {
        internal let errors: [PluginImportResult.ImportStatementError]
        internal let totalSkipped: Int
    }

    internal let outcome: Outcome
    internal let title: String
    internal let message: String
    internal let details: Details?
    internal let errorReport: ErrorReport?

    internal init(
        outcome: Outcome,
        title: String,
        message: String = "",
        details: Details? = nil,
        errorReport: ErrorReport? = nil
    ) {
        self.outcome = outcome
        self.title = title
        self.message = message
        self.details = details
        self.errorReport = errorReport
    }

    internal var severity: NoticeSeverity {
        switch outcome {
        case .succeeded: return .success
        case .succeededWithIssues, .stopped: return .warning
        case .failed: return .error
        }
    }

    // A failed or stopped job keeps its form, so the user can change it and run it again.
    internal var returnsToForm: Bool {
        outcome == .failed || outcome == .stopped
    }
}

// The root of a transfer sheet once its job ended, in place of an alert on top of the sheet.
internal struct TransferResultView<Accessory: View, Actions: View>: View {
    private let result: TransferResult
    private let onBack: (() -> Void)?
    private let onDone: () -> Void
    private let accessory: Accessory
    private let actions: Actions

    internal init(
        _ result: TransferResult,
        onBack: (() -> Void)? = nil,
        onDone: @escaping () -> Void,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder actions: () -> Actions
    ) {
        self.result = result
        self.onBack = onBack
        self.onDone = onDone
        self.accessory = accessory()
        self.actions = actions()
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(result.title)
                        .font(.headline)
                } icon: {
                    Image(systemName: result.severity.symbolName)
                        .foregroundStyle(result.severity.tint)
                        .accessibilityHidden(true)
                }
                if !result.message.isEmpty {
                    Text(result.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let details = result.details {
                TransferReportBox(details: details)
                    .id(details)
            }

            accessory

            DialogFooter {
                actions
                if let onBack {
                    Button(String(localized: "Back"), action: onBack)
                }
                Button(String(localized: "Done"), action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.regular)
        .padding(20)
        .frame(width: TransferProgressView.sheetWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-result")
    }
}

internal extension TransferResultView where Accessory == EmptyView {
    init(
        _ result: TransferResult,
        onBack: (() -> Void)? = nil,
        onDone: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(result, onBack: onBack, onDone: onDone, accessory: { EmptyView() }, actions: actions)
    }
}

internal extension TransferResultView where Accessory == EmptyView, Actions == EmptyView {
    init(_ result: TransferResult, onBack: (() -> Void)? = nil, onDone: @escaping () -> Void) {
        self.init(result, onBack: onBack, onDone: onDone, accessory: { EmptyView() }, actions: { EmptyView() })
    }
}

// The bezeled AppKit text view the result alerts carried, so a long report scrolls and selects the same way.
private struct TransferReportBox: NSViewRepresentable {
    let details: TransferResult.Details

    func makeNSView(context: Context) -> TransferReportView {
        TransferReportView(shown: details.shown, copied: details.copied)
    }

    func updateNSView(_ nsView: TransferReportView, context: Context) {}
}

#Preview("Import completed with errors") {
    TransferResultView(
        TransferResult(
            outcome: .succeededWithIssues,
            title: "Import completed with errors",
            message: "100,013 statements executed, 2 failed\n12.40 seconds",
            details: TransferResult.Details(
                shown: "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)",
                copied: "Line 412: Duplicate entry\nINSERT INTO users VALUES (1)"
            )
        ),
        onDone: {}
    ) {
        Button("Save Report…") {}
    }
}

#Preview("Import failed") {
    TransferResultView(
        TransferResult(outcome: .failed, title: "Import failed", message: "Failed at line 7. relation \"x\" does not exist"),
        onBack: {},
        onDone: {}
    )
}
