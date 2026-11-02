//
//  ConnectionRecoveryBar.swift
//  TablePro
//

import SwiftUI

internal struct ConnectionRecoveryBarContent: Equatable {
    let title: String
    let cause: String?
    let accessibilityLabel: String

    init(connectionName: String, progress: ConnectionRecoveryProgress) {
        let title = String(
            format: String(localized: "Reconnecting to %@ (%lld of %lld)"),
            connectionName,
            Int64(progress.attempt),
            Int64(progress.maxAttempts)
        )
        let cause = progress.cause.flatMap { $0.isEmpty ? nil : $0 }
        self.title = title
        self.cause = cause
        accessibilityLabel = cause.map { [title, $0].joined(separator: ", ") } ?? title
    }
}

// Over the content while the reconnect loop redials: the driver is kept, so the rows and tabs stay.
internal struct ConnectionRecoveryBar: View {
    let content: ConnectionRecoveryBarContent
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(content.title)
                            .font(.callout.weight(.semibold))
                        if let cause = content.cause {
                            Text(cause)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                        }
                    }
                    .lineLimit(1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(content.accessibilityLabel)

                Spacer(minLength: 8)

                Button(String(localized: "Cancel"), action: onCancel)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .paneBarBackground()
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-recovery-bar")
    }
}
