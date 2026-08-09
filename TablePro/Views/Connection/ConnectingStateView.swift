//
//  ConnectingStateView.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

/// Deliberately not built on `ContentUnavailableView`. Apple documents that view for content
/// that cannot be shown, a network error or an empty list, and every case it names is a state
/// the operation has already settled into. UIKit ships a separate `loading()` configuration for
/// work in flight and macOS ships no equivalent, so a connecting surface is assembled here.
internal struct ConnectingStateView: View {
    internal let connection: DatabaseConnection
    internal let onCancel: () -> Void

    @State private var observer: ConnectionStageObserver

    internal init(connection: DatabaseConnection, onCancel: @escaping () -> Void) {
        self.connection = connection
        self.onCancel = onCancel
        _observer = State(wrappedValue: ConnectionStageObserver(connectionId: connection.id))
    }

    internal var body: some View {
        VStack(spacing: 18) {
            ConnectionTypeIcon(type: connection.type, pulses: true)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .frame(height: 44)

            VStack(spacing: 6) {
                Text(connection.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ConnectionEndpointLabel(connection: connection)
            }

            progressLine

            Button(role: .cancel, action: onCancel) {
                Text(String(localized: "Cancel"))
                    .frame(minWidth: 80)
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityStatus)
    }

    @ViewBuilder
    private var progressLine: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(stepLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if observer.isTakingLonger {
                Text(String(localized: "This is taking longer than usual."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 420)
        .multilineTextAlignment(.center)
        .onChange(of: observer.stage) { _, newStage in
            guard let newStage else { return }
            announce(newStage)
        }
    }

    private var stepLabel: String {
        guard let stage = observer.stage else { return String(localized: "Opening the connection") }
        return ConnectionStageLabelFormatter.stepLabel(for: stage, connection: connection)
    }

    private var accessibilityStatus: String {
        guard let stage = observer.stage else {
            return String(format: String(localized: "Connecting to %@"), connection.name)
        }
        return ConnectionStageLabelFormatter.announcement(for: stage, connection: connection)
    }

    /// Posted per step rather than continuously. `updatesFrequently` is documented as a hint to
    /// poll, which is the wrong shape for a handful of discrete transitions.
    private func announce(_ stage: ConnectionStage) {
        AccessibilityNotification.Announcement(
            ConnectionStageLabelFormatter.announcement(for: stage, connection: connection)
        ).post()
    }
}
