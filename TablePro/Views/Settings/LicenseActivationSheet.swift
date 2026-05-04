//
//  LicenseActivationSheet.swift
//  TablePro
//
//  Standalone license activation dialog, presentable from anywhere as a sheet.
//

import SwiftUI

struct LicenseActivationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var licenseKeyInput = ""
    @State private var isActivating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.title)
                    .foregroundStyle(.secondary)

                Text("Activate License")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Enter your license key to unlock Pro features.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 20)

            // License key input
            VStack(spacing: 12) {
                TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $licenseKeyInput)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .multilineTextAlignment(.center)
                    .onSubmit { Task { await activate() } }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                }
            }
            .padding(.horizontal, 32)

            // Actions
            VStack(spacing: 10) {
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 32)
                } else {
                    Button("Activate") {
                        Task { await activate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(licenseKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                HStack(spacing: 16) {
                    Link("Purchase License", destination: LicenseConstants.pricingURL)
                        .font(.subheadline)

                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.subheadline)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(width: 400)
    }

    private func activate() async {
        errorMessage = nil
        isActivating = true
        defer { isActivating = false }

        do {
            try await LicenseManager.shared.activate(licenseKey: licenseKeyInput)
            dismiss()
        } catch {
            errorMessage = (error as? LicenseError)?.friendlyDescription ?? error.localizedDescription
        }
    }
}
