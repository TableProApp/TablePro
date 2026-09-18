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
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text("TablePro Is Locked")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Authenticate to access your database connections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Button {
                    Task { await unlock() }
                } label: {
                    Label(buttonTitle, systemImage: biometrySymbol)
                        .frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAuthenticating)
            }
        }
        .task { await unlock() }
    }

    private var buttonTitle: String {
        didFail ? String(localized: "Try Again") : String(localized: "Unlock")
    }

    private var biometrySymbol: String {
        switch lockState.biometry {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .unavailable: "lock.open"
        }
    }

    private func unlock() async {
        guard !isAuthenticating, lockState.isLocked else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        didFail = !(await lockState.unlock())
    }
}

struct PrivacyCoverView: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .ignoresSafeArea()
            .overlay {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
    }
}
