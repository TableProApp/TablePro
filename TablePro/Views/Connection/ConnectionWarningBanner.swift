//
//  ConnectionWarningBanner.swift
//  TablePro
//

import SwiftUI

/// The warning a server sent with a login that succeeded, shown in place rather than in an alert: the
/// connection works and nothing here acts on the warning, and the HIG keeps alerts for what needs action.
internal struct ConnectionWarningBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Connected with a warning"))
                    .font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(message)
            }

            Spacer(minLength: 8)

            Button {
                ClipboardService.shared.writeText(message)
            } label: {
                Image(systemName: "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Copy Warning"))
            .accessibilityLabel(String(localized: "Copy Warning"))

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Dismiss"))
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A shape style background reaches into the safe area by default, which tints the toolbar above.
        .background(.yellow.opacity(0.12), ignoresSafeAreaEdges: [])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-warning-banner")
    }
}

#Preview {
    VStack(spacing: 0) {
        ConnectionWarningBanner(
            message: "ORA-28002: the password will expire within 7 days",
            onDismiss: {}
        )
        Divider()
        Spacer()
    }
    .frame(width: 640, height: 200)
}
