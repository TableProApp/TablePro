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

    @ObservedObject private var licenseManager = LicenseManager.shared
    @State private var showsActivation = false

    var body: some View {
        switch action {
        case .activate:
            Button(action.title) { showsActivation = true }
                .sheet(isPresented: $showsActivation) {
                    LicenseActivationSheet()
                }
        case .renew, .purchase, .upgrade:
            Link(action.title, destination: SupportLinks.pricing(referrer))
        case .retryValidation:
            HStack(spacing: 6) {
                Button(action.title) {
                    Task { await licenseManager.revalidate() }
                }
                .disabled(licenseManager.isValidating)

                if licenseManager.isValidating {
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
    @ObservedObject private var licenseManager = LicenseManager.shared

    var body: some View {
        if let failure = licenseManager.checkFailure {
            Label {
                Text(LicensePresentation.checkFailureMessage(failure))
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

// A control a license unlocks says what it needs and offers the one way there.
struct LicenseGateRow: View {
    let feature: ProFeature

    @ObservedObject private var licenseManager = LicenseManager.shared

    var body: some View {
        if let notice = LicensePresentation.gate(for: feature, access: licenseManager.checkFeature(feature)) {
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
    // For a surface with no room for the outcome: the License pane holds the activation form and
    // shows how a check went.
    @MainActor
    func perform(referrer: SupportReferrer) {
        switch self {
        case .activate:
            WindowOpener.shared.openSettings(tab: .account)
        case .renew, .purchase, .upgrade:
            WebPageOpener.open(SupportLinks.pricing(referrer), scope: .https)
        case .retryValidation:
            WindowOpener.shared.openSettings(tab: .account)
            Task { await LicenseManager.shared.revalidate() }
        }
    }
}

@MainActor
internal enum LicenseGateAlert {
    // An alert only when there is a choice to make; a state with no action opens the License pane,
    // which explains it. A sheet, never runModal: a UI test without a license froze the app on it.
    static func present(for feature: ProFeature, in window: NSWindow?) {
        let access = LicenseManager.shared.checkFeature(feature)
        guard let notice = LicensePresentation.gate(for: feature, access: access) else { return }
        guard let action = notice.action else {
            WindowOpener.shared.openSettings(tab: .account)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = notice.title
        alert.informativeText = notice.message
        alert.addButton(withTitle: action.title)
        AlertHelper.addCancelButton(to: alert, title: String(localized: "Cancel"))
        AlertHelper.present(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            action.perform(referrer: .featureGate(feature))
        }
    }
}
