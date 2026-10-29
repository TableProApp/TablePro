//
//  SignInView.swift
//  TablePro
//

import SwiftUI

internal enum SignInCopy {
    // The emailed link opens the default browser, which the sign-in sheet never sees (clients.md, Code).
    static var codeHint: String {
        String(localized: "Signing in by email? Type the 6-digit code from the email in the sign-in sheet. The link in the email opens your browser instead.")
    }
}

internal struct SignInView: View {
    enum Purpose {
        case firstLaunch
        case requested
    }

    @ObservedObject var model: SignInModel
    let purpose: Purpose
    let authenticator: () -> any WebAuthenticating
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            switch model.phase {
            case .ready, .signingIn, .failed:
                signInContent
            case .signedIn(let email, let plan):
                signedInContent(email: email, plan: plan)
            case .deviceLimit:
                deviceLimitContent
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 440)
        .sheet(isPresented: $model.presentsDeviceLimit, onDismiss: { model.settle(presentsSheet: false) }) {
            DeviceLimitSheet(model: DeviceLimitModel(services: model.services))
        }
    }

    private var signInContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Sign in to TablePro")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Text("Your account unlocks the features your plan includes, on up to 3 devices. Everything else works without an account.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sign-in-error")
            }

            VStack(spacing: 10) {
                Button {
                    Task { await model.signIn(using: authenticator()) }
                } label: {
                    HStack(spacing: 8) {
                        if model.isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        }
                        Text("Sign In")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSigningIn)
                .accessibilityIdentifier("sign-in-window-sign-in")

                Button(action: onClose) {
                    Text(purpose == .firstLaunch ? String(localized: "Continue Without Account") : String(localized: "Not Now"))
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isSigningIn)
                .accessibilityIdentifier("sign-in-window-continue")
            }
            .controlSize(.large)

            Text(SignInCopy.codeHint)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func signedInContent(email: String?, plan: String?) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Label {
                    Text("You're signed in")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

                if let email {
                    Text(email)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let plan {
                    Text(plan)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onClose) {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("sign-in-window-done")
        }
    }

    private var deviceLimitContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("You're signed in")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                Text("Your plan is in use on 3 other devices. Remove one to use it on this Mac. Until then, TablePro works on the Free plan here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                Button {
                    model.presentsDeviceLimit = true
                } label: {
                    Text("Choose a Device…")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(action: onClose) {
                    Text("Not Now")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
    }
}
