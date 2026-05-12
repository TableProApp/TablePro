//
//  ConnectingStateView.swift
//  TablePro
//

import AppKit
import SwiftUI

struct ConnectingStateView: View {
    let connection: DatabaseConnection
    let onCancel: () -> Void
    private let iconIsSymbol: Bool

    init(connection: DatabaseConnection, onCancel: @escaping () -> Void) {
        self.connection = connection
        self.onCancel = onCancel
        self.iconIsSymbol = NSImage(
            systemSymbolName: connection.type.iconName,
            accessibilityDescription: nil
        ) != nil
    }

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(String(format: String(localized: "Connecting to %@"), connection.name))
            } icon: {
                iconView
            }
        } description: {
            VStack(spacing: 14) {
                if !endpointSubtitle.isEmpty {
                    Text(endpointSubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                ProgressView()
                    .controlSize(.small)
            }
        } actions: {
            Button(role: .cancel, action: onCancel) {
                Text(String(localized: "Cancel"))
                    .frame(minWidth: 80)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var iconView: some View {
        if iconIsSymbol {
            Image(systemName: connection.type.iconName)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, options: .repeating)
        } else {
            Image(connection.type.iconName)
                .resizable()
                .scaledToFit()
        }
    }

    private var endpointSubtitle: String {
        if connection.host.isEmpty { return connection.database }
        if connection.port > 0 {
            return "\(connection.host):\(connection.port)"
        }
        return connection.host
    }
}
