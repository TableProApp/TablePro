//
//  LicenseNoticeControls.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProHTTP

struct LicenseNoticeActionButton: View {
    let action: LicenseNoticeAction
    let referrer: SupportReferrer

    // Local: AccountServices runs one check at a time, and this button only needs to know its own is out.
    @State private var isChecking = false

    var body: some View {
        switch action {
        case .signIn:
            Button(action.title) { SignInWindowController.present() }
        case .purchase, .upgrade, .renew:
            Link(action.title, destination: SupportLinks.pricing(referrer))
                .countsUpgradeClicks(from: referrer)
        case .openAccountSettings:
            Button(action.title) { WindowOpener.shared.openSettings(tab: .account) }
        case .retryValidation:
            HStack(spacing: 6) {
                Button(action.title) {
                    isChecking = true
                    Task {
                        await AccountServices.shared.checkNow()
                        isChecking = false
                    }
                }
                .disabled(isChecking)

                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Checking…"))
                }
            }
        }
    }
}

// Kept on screen while a new check runs, so a repeat failure reads as the spinner coming and going.
struct LicenseCheckFailureLine: View {
    @ObservedObject private var featureAccess = FeatureAccess.shared

    var body: some View {
        if let failure = LicensePresentation.checkFailureMessage(featureAccess.state.refresh) {
            Label {
                Text(failure)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.callout)
        }
    }
}

// A control a plan unlocks says what it needs and offers the way there.
struct LicenseGateRow: View {
    let feature: ProFeature

    @ObservedObject private var featureAccess = FeatureAccess.shared

    var body: some View {
        if let notice = LicensePresentation.gate(for: feature, state: featureAccess.state, now: Date()) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)

                    Text(notice.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if notice.action == .retryValidation {
                        LicenseCheckFailureLine()
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if let alternative = notice.alternative {
                    LicenseNoticeActionButton(action: alternative, referrer: .featureGate(feature))
                }

                if let action = notice.action {
                    LicenseNoticeActionButton(action: action, referrer: .featureGate(feature))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("license-gate-\(feature.rawValue)")
        }
    }
}

extension LicenseNoticeAction {
    // For a surface with no room for the outcome: Settings > Account shows how a check went.
    @MainActor
    func perform(referrer: SupportReferrer) {
        switch self {
        case .signIn:
            SignInWindowController.present()
        case .purchase, .upgrade, .renew:
            Telemetry.shared.upgradeClicked(from: referrer)
            WebPageOpener.open(SupportLinks.pricing(referrer), scope: .https)
        case .openAccountSettings:
            WindowOpener.shared.openSettings(tab: .account)
        case .retryValidation:
            WindowOpener.shared.openSettings(tab: .account)
            Task { await AccountServices.shared.checkNow() }
        }
    }
}

@MainActor
internal enum LicenseGateAlert {
    // A sheet, never runModal: a UI test without a plan froze the app on it.
    static func present(for feature: ProFeature, in window: NSWindow?, access: FeatureAccess = .shared) {
        guard let notice = LicensePresentation.gate(for: feature, state: access.state, now: Date()) else { return }
        Telemetry.shared.featureGateShown(feature, access: access.check(feature))
        let actions = [notice.action, notice.alternative].compactMap { $0 }
        // A state with no way out of its own opens the pane that explains it.
        guard !actions.isEmpty else {
            WindowOpener.shared.openSettings(tab: .account)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        for action in actions {
            alert.addButton(withTitle: action.title)
        }
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        AlertHelper.present(alert, in: window) { response in
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard actions.indices.contains(index) else { return }
            actions[index].perform(referrer: .featureGate(feature))
        }
    }
}
