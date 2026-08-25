//
//  CompareProgressView.swift
//  TablePro
//
//  What the comparison is doing right now, how to stop it, and what it said.
//
//  Cancel updates the button synchronously and never waits on the driver:
//  `Task.cancel()` is cooperative, so a driver already blocked in a C call
//  cannot be interrupted and may complete long after the user gave up.
//
//  The root carries no padding of its own, so a host that already draws a strip
//  around it does not end up padding it twice.
//

import SwiftUI

internal struct CompareProgressView: View {
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isBusy {
                activityRow
            }
        }
    }

    private var activityRow: some View {
        HStack(spacing: 8) {
            progressBar
                .frame(maxWidth: 200)
            Button("Cancel") {
                session.cancelRunningWork()
            }
            .controlSize(.small)
            .accessibilityIdentifier("compare.progress.cancel")
        }
    }

    /// `session.progress` exists only for a run whose total is known. Everything else reports no
    /// countable unit of work, so it stays indeterminate rather than inventing one.
    @ViewBuilder
    private var progressBar: some View {
        if let progress = session.progress {
            ProgressView(progress)
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    @ViewBuilder
    private var messages: some View {
        Text(session.bannerText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if let message = session.errorMessage {
            messageLabel(message, systemImage: "exclamationmark.triangle.fill", tint: CompareStatusStyle.error)
        }

        if let message = session.informationalMessage {
            messageLabel(message, systemImage: "info.circle", tint: CompareStatusStyle.warning)
        }
    }

    private func messageLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(tint)
    }
}

/// Every error and notice the session raises, at the top of the pane the user is already reading.
///
/// A message is set exactly when work stops, so anything that renders one only while the session is
/// busy renders it never: a failed comparison, a capability refusal, a cross-engine warning, a
/// cancelled run, a denied Apply authorization and "Nothing is selected to apply." all produced no
/// output at all. It is inline rather than an alert because the HIG reserves an alert for a
/// situation the user must resolve before continuing and allows one at a time, and a restored
/// window can raise several at once.
internal struct CompareMessageBanner: View {
    @Bindable internal var session: CompareSyncSession

    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    internal var body: some View {
        if session.errorMessage != nil || session.informationalMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let message = session.errorMessage {
                    messageRow(
                        message,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: CompareStatusStyle.error,
                        identifier: "compare.message.dismissError"
                    ) {
                        session.errorMessage = nil
                    }
                }
                if let message = session.informationalMessage {
                    messageRow(
                        message,
                        systemImage: "info.circle.fill",
                        tint: CompareStatusStyle.warning,
                        identifier: "compare.message.dismissNotice"
                    ) {
                        session.informationalMessage = nil
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
        }
    }

    private func messageRow(
        _ text: String,
        systemImage: String,
        tint: Color,
        identifier: String,
        onDismiss: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage)
            }
            .foregroundStyle(differentiateWithoutColor ? Color.primary : tint)

            Spacer(minLength: 0)

            Button(String(localized: "Dismiss"), systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier(identifier)
        }
        .font(.callout)
    }
}
