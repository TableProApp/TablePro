//
//  ProFeatureGate.swift
//  TablePro
//

import SwiftUI

struct ProFeatureGateModifier: ViewModifier {
    let feature: ProFeature

    @ObservedObject private var featureAccess = FeatureAccess.shared

    func body(content: Content) -> some View {
        let notice = LicensePresentation.gate(for: feature, state: featureAccess.state, now: Date())

        content
            .disabled(notice != nil)
            .overlay {
                if let notice {
                    overlay(notice)
                }
            }
    }

    private func overlay(_ notice: LicenseNotice) -> some View {
        ZStack {
            AccessibleMaterialScrim(material: .ultraThinMaterial)

            VStack(spacing: 12) {
                Image(systemName: feature.systemImage)
                    .font(.largeTitle)
                    .imageScale(.large)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(notice.title)
                    .font(.headline)

                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let action = notice.action {
                    LicenseNoticeActionButton(action: action, referrer: .featureGate(feature))
                        .buttonStyle(.borderedProminent)
                }

                if let alternative = notice.alternative {
                    LicenseNoticeActionButton(action: alternative, referrer: .featureGate(feature))
                        .font(.subheadline)
                }

                if notice.action == .retryValidation {
                    LicenseCheckFailureLine()
                }
            }
            .frame(maxWidth: 420)
            .padding()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pro-feature-gate-\(feature.rawValue)")
        }
        .onAppear { Telemetry.shared.featureGateShown(feature, access: featureAccess.check(feature)) }
    }
}

extension View {
    func requiresPro(_ feature: ProFeature) -> some View {
        modifier(ProFeatureGateModifier(feature: feature))
    }
}
