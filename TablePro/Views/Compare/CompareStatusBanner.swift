//
//  CompareStatusBanner.swift
//  TablePro
//
//  States plainly whether anything has been written yet, and carries the target
//  connection's colour so a production target stays visually distinct.
//

import SwiftUI

internal struct CompareStatusBanner: View {
    internal let session: CompareSyncSession

    internal var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(session.bannerText)
                .font(.callout)
                .foregroundStyle(.primary)
            Spacer()
            if let target = session.target {
                HStack(spacing: 6) {
                    Circle()
                        .fill(target.color.color)
                        .frame(width: 9, height: 9)
                    Text(String(format: String(localized: "Target: %@"), target.qualifiedDescription))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08))
    }

    private var symbol: String {
        switch session.activity {
        case .applying: return "exclamationmark.triangle.fill"
        case .comparing, .connecting: return "magnifyingglass"
        case .idle: return session.hasWrittenToTarget ? "checkmark.circle" : "eye"
        }
    }

    private var tint: Color {
        switch session.activity {
        case .applying: return .orange
        case .comparing, .connecting: return .accentColor
        case .idle: return session.hasWrittenToTarget ? .green : .secondary
        }
    }
}

internal struct CompareSyncFooter: View {
    internal let session: CompareSyncSession
    @Binding internal var isConfirmingApply: Bool

    internal var body: some View {
        HStack(spacing: 12) {
            if let message = session.errorMessage {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(2)
            } else if let message = session.informationalMessage {
                Label(message, systemImage: "info.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(2)
            }

            Spacer()

            if session.isBusy {
                if let progress = session.progress {
                    ProgressView(progress)
                        .progressViewStyle(.linear)
                        .frame(width: 180)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(String(localized: "Cancel")) { session.cancelRunningWork() }
            } else {
                actionButtons
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.step {
        case .setup:
            Button(String(localized: "Compare")) { session.runComparison() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canCompare)
        case .review:
            Button(String(localized: "Back")) { session.step = .setup }
            Button(String(localized: "Generate Script")) { session.buildScript() }
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canBuildScript)
        case .script:
            Button(String(localized: "Back")) { session.step = .review }
            Button(String(localized: "Apply to Target")) { isConfirmingApply = true }
                .disabled(session.statements.isEmpty)
        case .apply:
            Button(String(localized: "Done")) { session.step = .setup }
                .keyboardShortcut(.defaultAction)
        }
    }
}
