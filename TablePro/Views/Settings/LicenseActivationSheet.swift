//
//  LicenseActivationSheet.swift
//  TablePro
//
//  Standalone license activation dialog, presentable from anywhere as a sheet.
//

import SwiftUI

/// A utility dialog around `LicenseActivationForm`, sized like its siblings.
///
/// It carries only what a sheet needs that a pane does not: a title, a Cancel button and a
/// dismissal. Everything about activating itself lives in the shared form, so this and the settings
/// pane cannot word the same failure two different ways again.
struct LicenseActivationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Activate License")
                    .font(.headline)

                Text("Enter your license key, or a team invite code to join a team.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LicenseActivationForm { dismiss() }

            HStack {
                Link("Purchase License", destination: SupportLinks.pricing(.activationSheet))
                    .font(.subheadline)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

#Preview {
    LicenseActivationSheet()
}
