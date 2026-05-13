import SwiftUI

struct ErrorView: View {
    let error: AppError
    var onRetry: (() async -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(error.title, systemImage: iconName)
        } description: {
            VStack(spacing: 8) {
                Text(verbatim: error.message)
                if let recovery = error.recovery {
                    Text(verbatim: recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            if let onRetry {
                Button("Retry") {
                    Task { await onRetry() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var iconName: String {
        switch error.category {
        case .network: return "wifi.exclamationmark"
        case .auth: return "lock.trianglebadge.exclamationmark"
        case .config: return "gear.badge.xmark"
        case .query: return "exclamationmark.triangle"
        case .ssh: return "terminal"
        case .system: return "xmark.circle"
        }
    }
}

struct ErrorToast: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
