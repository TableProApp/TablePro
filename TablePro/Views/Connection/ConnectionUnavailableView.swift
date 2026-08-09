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
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .symbolRenderingMode(.hierarchical)
        case .pluginMissing:
            Image(systemName: "puzzlepiece.extension")
                .symbolRenderingMode(.hierarchical)
        }
    }

    private var headline: String {
        switch reason {
        case .notConnected, .cancelled:
            return String(format: String(localized: "Not connected to %@"), connection.name)
        case .disconnected:
            return String(format: String(localized: "Disconnected from %@"), connection.name)
        case .failed, .pluginMissing:
            return String(format: String(localized: "Could not connect to %@"), connection.name)
        }
    }

    private var detailLines: [String] {
        switch reason {
        case .notConnected, .cancelled:
            return []
        case .disconnected(let info):
            guard let info else { return [String(localized: "The connection was closed.")] }
            return lines(from: info)
        case .failed(let info), .pluginMissing(let info):
            return lines(from: info)
        }
    }

    private var failureInfo: ConnectionFailureInfo? {
        switch reason {
        case .notConnected, .cancelled:
            return nil
        case .disconnected(let info):
            return info
        case .failed(let info), .pluginMissing(let info):
            return info
        }
    }

    /// The driver's own words are the part worth pasting into a bug report, so they go to the
    /// clipboard verbatim alongside enough context to identify the connection.
    private var copyableDetails: String? {
        guard let failureInfo else { return nil }
        return ([headline, connection.connectionSubtitle] + lines(from: failureInfo))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func lines(from info: ConnectionFailureInfo) -> [String] {
        [info.message, info.failureReason, info.recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    private var primaryActionTitle: String {
        switch reason {
        case .notConnected, .cancelled:
            return String(localized: "Connect")
        case .disconnected:
            return String(localized: "Reconnect")
        case .failed:
            return String(localized: "Try Again")
        case .pluginMissing:
            return String(localized: "Install Plugin…")
        }
    }
}
