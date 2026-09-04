//
//  ConnectionUnavailableView.swift
//  TablePro
//

import SwiftUI

internal struct ConnectionUnavailableView: View {
    internal let connection: DatabaseConnection
    internal let reason: ConnectionUnavailableReason
    internal let onPrimaryAction: () -> Void
    internal let onManageConnections: () -> Void

    internal var body: some View {
        ContentUnavailableView {
            Label {
                Text(headline)
            } icon: {
                icon
            }
        } description: {
            VStack(spacing: 8) {
                ConnectionEndpointLabel(connection: connection)
                ForEach(Array(detailLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 420)
        } actions: {
            HStack(spacing: 12) {
                Button(action: onPrimaryAction) {
                    Text(primaryActionTitle)
                        .frame(minWidth: 80)
                }
                .keyboardShortcut(.defaultAction)

                Button(action: onManageConnections) {
                    Text(String(localized: "Manage Connections…"))
                }

                if let copyableDetails {
                    Button {
                        ClipboardService.shared.writeText(copyableDetails)
                    } label: {
                        Text(String(localized: "Copy Details"))
                    }
                    .help(String(localized: "Copy the full error to the clipboard"))
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var icon: some View {
        switch reason {
        case .notConnected, .cancelled:
            ConnectionTypeIcon(type: connection.type)
        case .disconnected:
            Image(systemName: "bolt.horizontal.circle")
                .symbolRenderingMode(.hierarchical)
        case .disconnectedByUser:
            Image(systemName: "cable.connector.slash")
                .symbolRenderingMode(.hierarchical)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
        case .pluginMissing:
            Image(systemName: "puzzlepiece.extension")
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var headline: String {
        ConnectionUnavailablePresentation.headline(reason: reason, connectionName: connection.name)
    }

    private var detailLines: [String] {
        ConnectionUnavailablePresentation.detailLines(reason: reason)
    }

    private var failureInfo: ConnectionFailureInfo? {
        ConnectionUnavailablePresentation.failureInfo(reason: reason)
    }

    /// The driver's own words are the part worth pasting into a bug report, so they go to the
    /// clipboard verbatim alongside enough context to identify the connection.
    private var copyableDetails: String? {
        guard let failureInfo else { return nil }
        return ([headline, connection.connectionSubtitle]
            + ConnectionUnavailablePresentation.lines(from: failureInfo))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var primaryActionTitle: String {
        ConnectionUnavailablePresentation.primaryActionTitle(reason: reason)
    }
}
