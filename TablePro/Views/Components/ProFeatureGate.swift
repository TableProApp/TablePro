//
//  ProFeatureGate.swift
//  TablePro
//
//  View modifier that gates content behind a Pro license
//

import SwiftUI

/// Overlays a "Pro required" message on content when the user lacks an active license
struct ProFeatureGateModifier: ViewModifier {
    let feature: ProFeature

    private let licenseManager = LicenseManager.shared
    // swiftlint:disable:next force_unwrapping
    private static let pricingURL = URL(string: "https://tablepro.app/#pricing")!

    func body(content: Content) -> some View {
        let available = licenseManager.isFeatureAvailable(feature)

        content
            .disabled(!available)
            .overlay {
                if !available {
                    proRequiredOverlay
                }
            }
    }

    @ViewBuilder
    private var proRequiredOverlay: some View {
        let access = licenseManager.checkFeature(feature)

        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 12) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                switch access {
                case .available:
                    EmptyView()
                case .expired:
                    Text("Your license has expired")
                        .font(.headline)
                    Text(feature.featureDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Renew License...")) {
                        openLicenseSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Link(String(localized: "Renew License"), destination: Self.pricingURL)
                        .font(.subheadline)
                case .validationFailed:
                    Text("License validation failed")
                        .font(.headline)
                    Text("Connect to the internet to verify your license.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Retry Validation")) {
                        Task { await LicenseManager.shared.revalidate() }
                    }
                    .buttonStyle(.borderedProminent)
                case .unlicensed:
                    Text("\(feature.displayName) requires a Pro license")
                        .font(.headline)
                    Text(feature.featureDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Activate License...")) {
                        openLicenseSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    Link(String(localized: "Purchase License"), destination: Self.pricingURL)
                        .font(.subheadline)
                }
            }
            .padding()
        }
    }

    private func openLicenseSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            UserDefaults.standard.set(SettingsTab.license.rawValue, forKey: "selectedSettingsTab")
        }
    }
}

extension View {
    /// Gate this view behind a Pro license requirement
    func requiresPro(_ feature: ProFeature) -> some View {
        modifier(ProFeatureGateModifier(feature: feature))
    }
}
