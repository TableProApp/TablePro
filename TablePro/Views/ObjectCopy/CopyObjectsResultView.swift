//
//  CopyObjectsResultView.swift
//  TablePro
//
//  What the copy actually wrote.
//
//  A cancelled copy is neither a success nor a failure: the objects already
//  written are still there, so the result says which, rather than reporting the
//  whole run as one or the other.
//

import SwiftUI

internal struct CopyObjectsResultView: View {
    internal let session: ObjectCopySession

    internal var body: some View {
        if let result = session.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headline(result)
                    if let database = result.createdDatabase {
                        Label(
                            String(format: String(localized: "Created the database %@."), database),
                            systemImage: "cylinder.split.1x2"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                    outcomes(result)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .accessibilityIdentifier("copy-objects-result")
        } else {
            Color.clear
        }
    }

    private func headline(_ result: ObjectCopyRunResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title(result), systemImage: symbol(result))
                .font(.headline)
                .foregroundStyle(tint(result))
            Text(summary(result))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func title(_ result: ObjectCopyRunResult) -> String {
        if result.cancelled { return String(localized: "Copy stopped") }
        if result.failedCount > 0 { return String(localized: "Copy finished with errors") }
        return String(localized: "Copy finished")
    }

    private func symbol(_ result: ObjectCopyRunResult) -> String {
        if result.cancelled { return "stop.circle" }
        if result.failedCount > 0 { return "exclamationmark.triangle" }
        return "checkmark.circle"
    }

    private func tint(_ result: ObjectCopyRunResult) -> Color {
        if result.cancelled { return .secondary }
        return result.failedCount > 0 ? .orange : .green
    }

    private func summary(_ result: ObjectCopyRunResult) -> String {
        let objects = String(
            format: result.succeededCount == 1
                ? String(localized: "%@ object")
                : String(localized: "%@ objects"),
            result.succeededCount.formatted(.number.grouping(.automatic))
        )
        let rows = String(
            format: result.rowsCopied == 1
                ? String(localized: "%@ row")
                : String(localized: "%@ rows"),
            result.rowsCopied.formatted(.number.grouping(.automatic))
        )
        return String(format: String(localized: "%1$@, %2$@."), objects, rows)
    }

    @ViewBuilder
    private func outcomes(_ result: ObjectCopyRunResult) -> some View {
        let failures = result.failures
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Errors")
                    .font(.subheadline.weight(.medium))
                ForEach(failures) { failure in
                    Text(verbatim: "\(failure.outcome.selection.qualifiedName): \(failure.outcome.error ?? "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
