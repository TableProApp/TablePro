//
//  NoticeLabel.swift
//  TablePro
//

import SwiftUI

internal enum NoticeSeverity: Equatable, Sendable {
    case warning
    case error
    case success

    internal var symbolName: String {
        switch self {
        case .warning, .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    internal var tint: Color {
        switch self {
        case .warning: .orange
        case .error: .red
        case .success: .green
        }
    }
}

// A status line in a form, a sheet or a popover: the hue goes on the symbol only and the words stay
// secondary, so a warning never turns into colored text.
internal struct NoticeLabel: View {
    let text: String
    var severity: NoticeSeverity = .warning

    init(_ text: String, severity: NoticeSeverity = .warning) {
        self.text = text
        self.severity = severity
    }

    var body: some View {
        Label {
            Text(verbatim: text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: severity.symbolName)
                .foregroundStyle(severity.tint)
                .accessibilityHidden(true)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        NoticeLabel("Passwords do not match.", severity: .error)
        NoticeLabel("The server certificate is not verified.")
        NoticeLabel("Connection successful", severity: .success)
    }
    .padding()
}
