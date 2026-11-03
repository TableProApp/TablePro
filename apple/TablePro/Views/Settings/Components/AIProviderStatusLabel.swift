//
//  AIProviderStatusLabel.swift
//  TablePro
//

import SwiftUI

internal struct AIProviderStatusLabel: View {
    let status: AIProviderStatus
    var showsReadySymbol = true

    var body: some View {
        switch status {
        case .checking, .signingIn:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(status.title)
                    .foregroundStyle(.secondary)
            }
        default:
            if let severity = status.severity {
                NoticeLabel(status.title, severity: severity)
            } else if showsReadySymbol {
                NoticeLabel(status.title, severity: .success)
            } else {
                Text(status.title)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
