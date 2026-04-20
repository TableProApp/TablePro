//
//  LicenseSettingsView.swift
//  TablePro
//
//  License settings tab: status display, activation form, and deactivation
//

import AppKit
import os
import SwiftUI

struct LicenseSettingsView: View {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LicenseSettingsView")

    private let licenseManager = LicenseManager.shared

    @State private var licenseKeyInput = ""
    @State private var isActivating = false
    @State private var activations: [LicenseActivationInfo] = []
    @State private var maxActivations = 0
    @State private var isLoadingActivations = false
    @State private var hasLoadedActivations = false
    @State private var activationLoadError: String?

    var body: some View {
        Form {
            if let license = licenseManager.license {
                licensedSection(license)
            } else {
                unlicensedSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            guard !hasLoadedActivations else { return }
            await loadActivations()
            hasLoadedActivations = true
        }
    }

    // MARK: - Licensed State

    @ViewBuilder
    private func licensedSection(_ license: License) -> some View {
        if licenseManager.isExpiringSoon, let days = licenseManager.daysUntilExpiry {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("License expires in \(days) day(s)")
                Spacer()
                Link(String(localized: "Renew"), destination: LicenseConstants.pricingURL)
                    .controlSize(.small)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }

        Section("License") {
            LabeledContent("Email:", value: license.email)

            LabeledContent("License Key:") {
                Text(maskedKey(license.key))
                    .textSelection(.enabled)
            }

            LabeledContent("Status:") {
                Text(license.status.displayName)
                    .foregroundStyle(license.status.isValid ? .green : .red)
            }

            if let expiresAt = license.expiresAt {
                LabeledContent("Expires:", value: expiresAt.formatted(date: .abbreviated, time: .omitted))
            } else {
                LabeledContent("Expires:", value: String(localized: "Lifetime"))
            }

            LabeledContent("Tier:", value: license.tier.capitalized)

            if let billingCycle = license.billingCycle {
                LabeledContent("Billing:", value: billingCycle.capitalized)
            }
        }

        Section("Activations (\(activations.count) of \(maxActivations))") {
            if isLoadingActivations {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
            } else if activations.isEmpty && activationLoadError == nil {
                Text("No activations found")
                    .foregroundStyle(.secondary)
            }
            if let error = activationLoadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
            if !activations.isEmpty {
                ForEach(activations) { activation in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(activation.machineName)
                                    .fontWeight(
                                        activation.machineId == LicenseStorage.shared.machineId
                                            ? .semibold : .regular
                                    )
                                if activation.machineId == LicenseStorage.shared.machineId {
                                    Text("(this Mac)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(activation.appVersion + " · " + activation.osVersion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Refresh") {
                    Task { await loadActivations() }
                }
                .disabled(isLoadingActivations)
            }
        }

        Section("Maintenance") {
            HStack {
                Text("Refresh license status from server")
                Spacer()
                Button("Check Status") {
                    Task { await licenseManager.revalidate() }
                }
                .disabled(licenseManager.isValidating)
            }

            HStack {
                Text("Remove license from this machine")
                Spacer()
                Button("Deactivate...") {
                    Task { @MainActor in
                        let confirmed = await AlertHelper.confirmDestructive(
                            title: String(localized: "Deactivate License?"),
                            message: String(localized: "This will remove the license from this machine. You can reactivate later."),
                            confirmButton: String(localized: "Deactivate"),
                            cancelButton: String(localized: "Cancel")
                        )

                        if confirmed {
                            await deactivate()
                        }
                    }
                }
                .disabled(licenseManager.isValidating)
            }
        }
    }

    // MARK: - Unlicensed State

    private var unlicensedSection: some View {
        Section("License") {
            TextField("License Key:", text: $licenseKeyInput)
                .font(.system(.body, design: .monospaced))
                .disableAutocorrection(true)
                .onSubmit { Task { await activate() } }

            HStack {
                Spacer()
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Activate") {
                        Task { await activate() }
                    }
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || isActivating)
                }
            }

            HStack {
                Spacer()
                Link("Purchase License", destination: LicenseConstants.pricingURL)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Helpers

    private func maskedKey(_ key: String) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 5 else { return key }
        let first = String(parts[0])
        let masked = Array(repeating: "*****", count: 4).joined(separator: "-")
        return "\(first)-\(masked)"
    }

    // MARK: - Actions

    private func loadActivations() async {
        guard let license = licenseManager.license else { return }
        isLoadingActivations = true
        defer { isLoadingActivations = false }

        do {
            let response = try await LicenseAPIClient.shared.listActivations(
                licenseKey: license.key,
                machineId: LicenseStorage.shared.machineId
            )
            activations = response.activations
            maxActivations = response.maxActivations
        } catch {
            Self.logger.debug("Failed to load activations: \(error.localizedDescription)")
            activationLoadError = error.localizedDescription
        }
    }

    private func activate() async {
        isActivating = true
        defer { isActivating = false }

        do {
            try await licenseManager.activate(licenseKey: licenseKeyInput)
            licenseKeyInput = ""
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Activation Failed"),
                message: (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription,
                window: NSApp.keyWindow
            )
        }
    }

    private func deactivate() async {
        let serverSuccess = await licenseManager.deactivate()
        if !serverSuccess {
            AlertHelper.showInfoSheet(
                title: String(localized: "License Removed"),
                message: String(localized: "License removed from this Mac, but the server could not be reached. The activation slot may not be freed until it expires."),
                window: NSApp.keyWindow
            )
        }
    }
}

#Preview("Unlicensed") {
    LicenseSettingsView()
        .frame(width: 450, height: 300)
}
