import SwiftUI

struct ErrorView: View {
    let error: AppError
    // A lost session reads as lost, whatever its redial failed on.
    var title: String?
    var systemImage: String?
    var retryTitle = String(localized: "Retry")
    var onRetry: (() async -> Void)?
    var onEditConnection: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title ?? error.title, systemImage: systemImage ?? iconName)
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
        Button(retryTitle) {
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
