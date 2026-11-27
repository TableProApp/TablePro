//
//  TransferProgressView.swift
//  TablePro
//

import SwiftUI

internal struct TransferProgressView: View {
    internal static let sheetWidth: CGFloat = 420

    internal let progress: TransferProgress

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(progress.title)
                .font(.headline)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(progress.itemText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let amount = progress.amountText {
                    Text(amount)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            bar
                .accessibilityLabel(progress.title)

            if let note = progress.note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transfer-progress")
    }

    @ViewBuilder
    private var bar: some View {
        if let fraction = progress.fraction {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
        }
    }
}

// Escape reaches it through the cancel shortcut, so the key asks the same question the button does.
internal struct TransferStopButton: View {
    internal let policy: TransferStopPolicy
    internal var isStopping = false
    internal let onStop: () -> Void

    @State private var isConfirming = false
    @State private var hasConfirmed = false

    internal var body: some View {
        Button(stopping ? policy.stoppingTitle : policy.buttonTitle) {
            isConfirming = true
        }
        .keyboardShortcut(.cancelAction)
        .disabled(stopping)
        .alert(policy.confirmationTitle, isPresented: $isConfirming) {
            Button(String(localized: "Continue"), role: .cancel) {}
            Button(policy.confirmButton, role: .destructive) {
                hasConfirmed = true
                onStop()
            }
        } message: {
            Text(policy.consequence)
        }
    }

    private var stopping: Bool {
        isStopping || hasConfirmed
    }
}

// The root of a transfer sheet while its job runs. A job whose stop needs more than one question passes its own control.
internal struct TransferProgressSheet<StopControl: View>: View {
    internal let progress: TransferProgress
    private let stopControl: StopControl

    internal init(progress: TransferProgress, @ViewBuilder stopControl: () -> StopControl) {
        self.progress = progress
        self.stopControl = stopControl()
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TransferProgressView(progress: progress)
            HStack {
                Spacer()
                stopControl
            }
        }
        .controlSize(.regular)
        .padding(20)
        .frame(width: TransferProgressView.sheetWidth)
        .interactiveDismissDisabled()
    }
}

internal extension TransferProgressSheet where StopControl == TransferStopButton {
    init(progress: TransferProgress, onStop: @escaping () -> Void) {
        self.init(progress: progress) {
            TransferStopButton(policy: progress.stopPolicy, isStopping: progress.isStopping, onStop: onStop)
        }
    }
}

#Preview("Export") {
    TransferProgressSheet(
        progress: TransferProgress(
            job: .export,
            item: "users",
            step: .init(index: 1, count: 3),
            completed: 95_500,
            total: 175_787,
            unit: .rows
        ),
        onStop: {}
    )
}

#Preview("Restore") {
    TransferProgressSheet(
        progress: TransferProgress(job: .restore, item: "production", unit: .bytes),
        onStop: {}
    )
}
