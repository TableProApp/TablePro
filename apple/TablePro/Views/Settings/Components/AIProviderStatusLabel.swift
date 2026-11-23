import SwiftUI

internal struct AIProviderStatusLabel: View {
    let status: AIProviderStatus
    var showsReadySymbol = true

    var body: some View {
        switch status {
        case .checking, .signingIn:
            Label {
                Text(verbatim: status.title)
                    .foregroundStyle(.secondary)
            } icon: {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
        default:
            if let severity = status.severity {
                NoticeLabel(status.title, severity: severity)
            } else if showsReadySymbol, status.isReady {
                NoticeLabel(status.title, severity: .success)
            } else {
                Text(verbatim: status.title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
