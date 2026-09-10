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
///
/// Mounted from the moment the window opens, and holding its own card back until the connect
/// outlasts `LoadingRevealPolicy.grace`. The window used to hold the whole view back instead,
/// through a pane case that drew nothing, which cost the connect its first stages: the stage
/// subject has no replay, and an observer that does not exist yet cannot hear one. Mounting early
/// and revealing late is what puts the tunnel's own step on screen instead of the fallback.
internal struct ConnectingStateView: View {
    internal let connection: DatabaseConnection
    internal let onCancel: () -> Void

    @State private var observer: ConnectionStageObserver
    @State private var showsCard = false

    /// The description line keeps its height whether or not it has anything to say, so the bar
    /// under it and the Cancel button under that never move when a step arrives or goes.
    @ScaledMetric(relativeTo: .callout) private var descriptionHeight: CGFloat = 16

    internal init(connection: DatabaseConnection, onCancel: @escaping () -> Void) {
        self.connection = connection
        self.onCancel = onCancel
        _observer = State(wrappedValue: ConnectionStageObserver(connectionId: connection.id))
    }

    internal var body: some View {
        Group {
            if showsCard {
                card
            } else {
                /// The pane draws nothing for the first `LoadingRevealPolicy.grace`, and draws it
                /// as a full-size empty colour rather than as nothing at all. `LoadingReveal`
                /// renders no content while it is held back, and measured in this position, as the
                /// root of a pane's `rootView`, that leaves the hosting controller with no view to
                /// attach a `frame` or a `task` to: the reveal never armed and the card never came.
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .loadingRevealGate(isActive: true, isRevealed: $showsCard)
        /// Attached out here rather than to the card, so a step that lands before the card does is
        /// still spoken. VoiceOver is told what is happening from the first stage; the card is held
        /// back only because a picture nobody has time to read is worth less than a still window.
        .onChange(of: observer.stage) { _, newStage in
            guard let newStage else { return }
            announce(newStage)
        }
    }

    private var card: some View {
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

    /// A bar rather than a spinner, and the description above it rather than beside it.
    ///
    /// Measured on macOS 27: Finder's Connect to Server draws "Connecting to smb://… " over a
    /// horizontal `AXOrientation=AXHorizontalOrientation` busy indicator, and Screen Sharing
    /// repeats it. That is the shape the HIG's two rules leave standing: "Avoid labeling a
    /// spinning progress indicator" rules out text next to a spinner, so an operation that has
    /// something to say uses the control that can carry it. Apple never labels a spinner because
    /// Apple never reaches for one here.
    @ViewBuilder
    private var progressLine: some View {
        VStack(spacing: 6) {
            Text(stepDescription ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: descriptionHeight)

            ProgressView()
                .progressViewStyle(.linear)

            if observer.isTakingLonger {
                Text(String(localized: "This is taking longer than usual."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: 420)
        .multilineTextAlignment(.center)
    }

    private var stepDescription: String? {
        guard let stage = observer.stage else { return nil }
        return ConnectionStageLabelFormatter.description(for: stage, connection: connection)
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
