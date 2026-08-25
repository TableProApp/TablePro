//
//  SupportView.swift
//  TablePro
//

import AppKit
import SwiftUI

/// States how TablePro is paid for and offers the two ways to pay for it. Nothing else: no
/// counter, no progress bar, no appeal. It is only ever reached because someone went looking for
/// it in the Help menu.
struct SupportView: View {
    private let licenseManager = LicenseManager.shared

    var body: some View {
        VStack(spacing: 20) {
            appIcon

            VStack(spacing: 12) {
                ForEach(paragraphs, id: \.self) { paragraph in
                    Text(paragraph)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.secondary)

            actions
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }

    private var paragraphs: [String] {
        switch licenseManager.supportAudience {
        case .supporter:
            return [
                String(localized: "Thanks. Your license is what pays for the next release."),
                String(
                    localized: """
                    TablePro takes no funding and sells no data. If you want to do more, \
                    sponsorship goes to the same place.
                    """
                )
            ]
        case .prospect:
            return [
                String(
                    localized: """
                    TablePro takes no funding, sells no data, and has no investors to answer to. \
                    Licenses are the whole business model.
                    """
                ),
                String(
                    localized: """
                    The app stays free, all of it. If TablePro is useful to you, a license is what \
                    pays for the next release.
                    """
                )
            ]
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            if licenseManager.supportAudience == .prospect {
                Link("Buy a License", destination: SupportLinks.pricing(.supportWindow))
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("support-buy-license")
            }

            Link("Sponsor on GitHub", destination: SupportLinks.sponsors(.supportWindow))
                .buttonStyle(.bordered)
                .accessibilityIdentifier("support-sponsor")
        }
        .controlSize(.large)
    }
}

#Preview {
    SupportView()
}
