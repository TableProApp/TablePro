//
//  ConnectionWarningBanner.swift
//  TablePro
//

import SwiftUI

// A server warning on a login that worked shows in place: nothing here acts on it, and the HIG keeps
// alerts for what needs a decision.
internal struct ConnectionWarningBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        PaneNoticeBar(severity: .warning, onDismiss: onDismiss) {
            PaneNoticeText(
                title: String(localized: "Connected with a warning"),
                detail: message,
                detailLineLimit: 3
            )
        } actions: {
            PaneNoticeCopyButton(text: message, label: String(localized: "Copy Warning"))
        }
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
