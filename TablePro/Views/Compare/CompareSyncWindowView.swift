//
//  CompareSyncWindowView.swift
//  TablePro
//
//  Root of the Compare & Sync auxiliary window. Steps advance in one direction
//  and the banner never lets the user forget which side is written to.
//

import SwiftUI

internal struct CompareSyncWindowView: View {
    internal let prefillSourceConnectionId: UUID?

    @State private var session = CompareSyncSession()
    @State private var isConfirmingApply = false
    @State private var isConfirmingClose = false

    internal var body: some View {
        VStack(spacing: 0) {
            CompareSyncStepHeader(session: session)
            Divider()
            CompareStatusBanner(session: session)
            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            CompareSyncFooter(session: session, isConfirmingApply: $isConfirmingApply)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { applyPrefill() }
        .alert(String(localized: "Apply changes?"), isPresented: $isConfirmingApply) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Apply")) { session.apply() }
        } message: {
            Text(applyConfirmationMessage)
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch session.step {
        case .setup:
            CompareSyncSetupView(session: session)
        case .review:
            if session.mode == .structure {
                StructureCompareReviewView(session: session)
            } else {
                DataCompareReviewView(session: session)
            }
        case .script:
            CompareSyncScriptView(session: session)
        case .apply:
            CompareSyncApplyView(session: session)
        }
    }

    private var applyConfirmationMessage: String {
        let runnable = session.statements.filter { session.executionSettings.canRun($0) }.count
        let heldBack = session.statements.count - runnable
        let target = session.target?.qualifiedDescription ?? ""
        guard heldBack > 0 else {
            return String(
                format: String(localized: "%d statements will run against %@. This cannot be undone automatically."),
                runnable, target
            )
        }
        return String(
            format: String(localized: "%d statements will run against %@. %d are held back as unsafe. This cannot be undone automatically."),
            runnable, target, heldBack
        )
    }

    private func applyPrefill() {
        guard let prefillSourceConnectionId, session.source == nil else { return }
        let connections = ConnectionStorage.shared.loadConnections()
        guard let match = connections.first(where: { $0.id == prefillSourceConnectionId }) else { return }
        session.source = CompareSyncEndpoint.candidates(from: [match]).first
    }
}

internal struct CompareSyncStepHeader: View {
    internal let session: CompareSyncSession

    internal var body: some View {
        HStack(spacing: 12) {
            ForEach(CompareSyncStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: step))
                        .foregroundStyle(step <= session.step ? Color.accentColor : Color.secondary)
                    Text(step.title)
                        .fontWeight(step == session.step ? .semibold : .regular)
                        .foregroundStyle(step <= session.step ? Color.primary : Color.secondary)
                }
                if step != CompareSyncStep.allCases.last {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func symbol(for step: CompareSyncStep) -> String {
        guard step != session.step else { return "\(step.rawValue + 1).circle.fill" }
        return step < session.step ? "checkmark.circle.fill" : "\(step.rawValue + 1).circle"
    }
}
