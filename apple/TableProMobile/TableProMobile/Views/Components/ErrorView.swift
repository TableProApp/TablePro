import SwiftUI

struct ErrorView: View {
    let error: AppError
    var onRetry: (() async -> Void)?
    var onEditConnection: (() -> Void)?

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
            if error.opensEditor, let onEditConnection {
                Button("Edit Connection", action: onEditConnection)
                    .buttonStyle(.borderedProminent)
                if let onRetry {
                    retryButton(onRetry)
                        .buttonStyle(.bordered)
                }
            } else if let onRetry {
                retryButton(onRetry)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func retryButton(_ onRetry: @escaping () async -> Void) -> some View {
        Button("Retry") {
            Task { await onRetry() }
        }
    }

    private var iconName: String {
        switch error.category {
        case .network: return "wifi.exclamationmark"
        case .auth: return "lock.trianglebadge.exclamationmark"
        case .permission: return "hand.raised"
        case .config: return "gear.badge.xmark"
        case .query: return "exclamationmark.triangle"
        case .ssh: return "terminal"
        case .system: return "xmark.circle"
        }
    }
}
