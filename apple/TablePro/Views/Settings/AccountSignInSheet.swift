//
//  AccountSignInSheet.swift
//  TablePro
//

import SwiftUI

// Stands in for the first-launch window and Settings > Account until M16.5 and M16.6 replace it.
struct AccountSignInSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var isSigningIn = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to TablePro")
                    .font(.headline)

                Text("Your account unlocks the paid features your plan includes on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account-sign-in-error")
            }

            HStack {
                Link("Purchase License", destination: SupportLinks.pricing(.activationSheet))
                    .font(.subheadline)

                Spacer()

                if isSigningIn {
                    ProgressView().controlSize(.small)
                }

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button(String(localized: "Sign In")) { signIn() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSigningIn)
                    .accessibilityIdentifier("account-sign-in-button")
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func signIn() {
        Task {
            failure = nil
            isSigningIn = true
            defer { isSigningIn = false }
            do throws(AccountError) {
                try await AccountServices.shared.signIn(using: WebAuthenticationSessionAuthenticator())
                dismiss()
            } catch {
                failure = error.friendlyDescription
            }
        }
    }
}

#Preview {
    AccountSignInSheet()
}
