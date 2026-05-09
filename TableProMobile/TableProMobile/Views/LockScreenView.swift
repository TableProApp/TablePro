//
//  LockScreenView.swift
//  TableProMobile
//

import SwiftUI

struct LockScreenView: View {
    @Environment(AppLockState.self) private var lockState
    @State private var isAuthenticating = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 6) {
                    Text("TablePro is Locked")
                        .font(.title2.weight(.semibold))
                    Text("Authenticate to access your database connections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Button {
                    Task { await unlock() }
                } label: {
                    Label(
                        didFail ? String(localized: "Try Again") : String(localized: "Unlock"),
                        systemImage: "faceid"
                    )
                    .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
        }
        .task { await unlock() }
    }

    private func unlock() async {
        guard !isAuthenticating, lockState.isLocked else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let success = await lockState.unlock()
        if !success {
            didFail = true
        }
    }
}
