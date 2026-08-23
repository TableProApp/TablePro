//
//  CompareProgressView.swift
//  TablePro
//
//  What the comparison is doing right now, and how to stop it.
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

    /// A host that already shows the banner passes `false` rather than repeating it.
    internal var showsMessages = true

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.isBusy {
                activityRow
            }
            if showsMessages {
                messages
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
