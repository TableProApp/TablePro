//
//  ClipboardConnectionBanner.swift
//  TablePro
//

import SwiftUI

struct ClipboardConnectionBanner: View {
    let candidate: ClipboardConnectionCandidate
    let onUse: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(String(localized: "Use clipboard URL"))
                .font(.callout)
                .foregroundStyle(.primary)

            Text(Self.summary(for: candidate))
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(0)

            Spacer(minLength: 8)

            Button(action: onUse) {
                Text(String(localized: "Use"))
            }
            .buttonStyle(.link)
            .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.4))
        .overlay(alignment: .bottom) {
            Rectangle()
                .frame(height: 0.5)
                .foregroundStyle(.separator)
        }
    }

    static func summary(for candidate: ClipboardConnectionCandidate) -> String {
        let parsed = candidate.parsed
        var rendered = candidate.scheme + "://"
        if !parsed.username.isEmpty {
            rendered += parsed.username
            if !parsed.password.isEmpty {
                rendered += ":***"
            }
            rendered += "@"
        }
        rendered += parsed.host
        if !parsed.useSrv, parsed.localSocketPath == nil, parsed.resolvedPort > 0 {
            rendered += ":\(parsed.resolvedPort)"
        }
        if !parsed.database.isEmpty {
            rendered += "/\(parsed.database)"
        }
        if let socketPath = parsed.localSocketPath {
            rendered += "?socket=\(socketPath)"
        }
        if rendered.count > 60 {
            let prefix = rendered.prefix(48)
            let suffix = rendered.suffix(8)
            rendered = "\(prefix)…\(suffix)"
        }
        return rendered
    }
}
