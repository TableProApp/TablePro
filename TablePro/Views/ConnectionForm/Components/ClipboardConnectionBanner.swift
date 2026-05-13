//
//  ClipboardConnectionBanner.swift
//  TablePro
//

import SwiftUI

struct ClipboardConnectionBanner: View {
    let parsed: ParsedConnection
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

            Text(Self.summary(for: parsed))
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

    static func summary(for parsed: ParsedConnection) -> String {
        var rendered = parsed.rawScheme + "://"
        if let user = parsed.username, !user.isEmpty {
            rendered += user
            if parsed.password != nil {
                rendered += ":***"
            }
            rendered += "@"
        }
        rendered += parsed.host
        if parsed.port > 0 {
            rendered += ":\(parsed.port)"
        }
        if let database = parsed.database {
            rendered += "/\(database)"
        }
        if rendered.count > 60 {
            let prefix = rendered.prefix(48)
            let suffix = rendered.suffix(8)
            rendered = "\(prefix)...\(suffix)"
        }
        return rendered
    }
}
