//
//  ProFeatureGate.swift
//  TablePro
//

import SwiftUI

struct ProFeatureGateModifier: ViewModifier {
    let feature: ProFeature

    @ObservedObject private var featureAccess = FeatureAccess.shared

    @State private var showSignInSheet = false

    func body(content: Content) -> some View {
        let access = featureAccess.check(feature)

        content
            .disabled(access != .available)
            .overlay {
                if access != .available {
                    lockedOverlay(access)
                }
            }
            .sheet(isPresented: $showSignInSheet) {
                AccountSignInSheet()
            }
    }

    private func lockedOverlay(_ access: ProFeatureAccess) -> some View {
        ZStack {
            AccessibleMaterialScrim(material: .ultraThinMaterial)

            VStack(spacing: 12) {
                Image(systemName: feature.systemImage)
                    .font(.largeTitle)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                switch access {
                case .available:
                    EmptyView()
                case .signedOut:
                    Text(feature.paidPlanRequirement)
                        .font(.headline)
                        .accessibilityIdentifier("pro-feature-gate-\(feature.rawValue)")
                    Text(feature.featureDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Sign In")) {
                        showSignInSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    Link(String(localized: "Purchase License"), destination: SupportLinks.pricing(.featureGate(feature)))
                        .font(.subheadline)
                case .notIncluded:
                    Text(feature.paidPlanRequirement)
                        .font(.headline)
                        .accessibilityIdentifier("pro-feature-gate-\(feature.rawValue)")
                    Text(feature.featureDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Link(String(localized: "Upgrade Plan"), destination: SupportLinks.pricing(.featureGate(feature)))
                        .buttonStyle(.borderedProminent)
                case .expired:
                    Text("Your license has expired")
                        .font(.headline)
                    Text(feature.featureDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Try Again")) {
                        Task { await AccountServices.shared.refreshEntitlement() }
                    }
                    .buttonStyle(.borderedProminent)
                    Link(String(localized: "Renew License"), destination: SupportLinks.pricing(.featureGate(feature)))
                        .font(.subheadline)
                case .refreshFailed:
                    Text("License validation failed")
                        .font(.headline)
                    Text("Connect to the internet to verify your license.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Retry Validation")) {
                        Task { await AccountServices.shared.refreshEntitlement() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}

extension View {
    func requiresPro(_ feature: ProFeature) -> some View {
        modifier(ProFeatureGateModifier(feature: feature))
    }
}
