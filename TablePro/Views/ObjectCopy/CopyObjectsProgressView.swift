//
//  CopyObjectsProgressView.swift
//  TablePro
//
//  What the copy is doing, and how far along it is.
//
//  The bar is driven by an approximate row count, which several engines answer
//  from statistics rather than by counting, so it is deliberately indeterminate
//  when nothing usable came back rather than pretending to a precision it does
//  not have.
//

import SwiftUI

internal struct CopyObjectsProgressView: View {
    internal let session: ObjectCopySession

    internal var body: some View {
        VStack(spacing: 16) {
            Text(session.currentObject.isEmpty
                ? String(localized: "Preparing…")
                : session.currentObject)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            Text(rowsText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityIdentifier("copy-objects-progress")
    }

    private var fraction: Double? {
        guard let total = session.plan?.estimatedRowTotal, total > 0 else { return nil }
        return min(1, Double(session.copiedRows) / Double(total))
    }

    private var rowsText: String {
        let copied = session.copiedRows.formatted(.number.grouping(.automatic))
        guard let total = session.plan?.estimatedRowTotal, total > 0 else {
            let template = session.copiedRows == 1
                ? String(localized: "%@ row copied")
                : String(localized: "%@ rows copied")
            return String(format: template, copied)
        }
        return String(
            format: String(localized: "%1$@ of about %2$@ rows"),
            copied, total.formatted(.number.grouping(.automatic))
        )
    }
}
