import AppKit
import SwiftUI

enum IntegrationStatus: Equatable {
    case running
    case stopped
    case starting
    case failed
    case success
    case error
    case warning
    case expired
    case revoked
    case active
}

struct IntegrationStatusIndicator: View {
    let status: IntegrationStatus
    var label: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .imageScale(.small)
                .accessibilityHidden(true)
            if let label {
                Text(label)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbolName: String {
        switch status {
        case .running, .success, .active:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .starting:
            return "clock.fill"
        case .failed, .error, .revoked:
            return "xmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .expired:
            return "clock.badge.exclamationmark.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .running, .success, .active:
            return Color(nsColor: .systemGreen)
        case .stopped:
            return Color(nsColor: .secondaryLabelColor)
        case .starting:
            return Color(nsColor: .systemOrange)
        case .failed, .error:
            return Color(nsColor: .systemRed)
        case .warning, .expired:
            return Color(nsColor: .systemOrange)
        case .revoked:
            return Color(nsColor: .systemRed)
        }
    }

    var accessibilityDescription: String {
        let prefix: String
        switch status {
        case .running:
            prefix = String(localized: "Status: running")
        case .stopped:
            prefix = String(localized: "Status: stopped")
        case .starting:
            prefix = String(localized: "Status: starting")
        case .failed:
            prefix = String(localized: "Status: failed")
        case .success:
            prefix = String(localized: "Status: success")
        case .error:
            prefix = String(localized: "Status: error")
        case .warning:
            prefix = String(localized: "Status: warning")
        case .expired:
            prefix = String(localized: "Status: expired")
        case .revoked:
            prefix = String(localized: "Status: revoked")
        case .active:
            prefix = String(localized: "Status: active")
        }
        guard let label, !label.isEmpty else { return prefix }
        return String(format: String(localized: "%1$@, %2$@"), prefix, label)
    }
}
