//
//  PaneNoticeBar.swift
//  TablePro
//

import SwiftUI

// The one shape for a notice over a pane, as the transaction and recovery bars draw it: color only on
// the symbol, small stock buttons, the pane bar material. A sheet passes `onBar: false`, since a bar
// material inside a sheet reads as a stray band.
internal struct PaneNoticeBar<Content: View, Actions: View>: View {
    let severity: NoticeSeverity
    var alignment: VerticalAlignment = .center
    var onBar = true
    var dismissLabel = String(localized: "Dismiss")
    var onDismiss: (() -> Void)?
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        let bar = HStack(alignment: alignment, spacing: 10) {
            HStack(alignment: alignment, spacing: 8) {
                Image(systemName: severity.symbolName)
                    .foregroundStyle(severity.tint)
                    .accessibilityHidden(true)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            actions
            if let onDismiss {
                Button(dismissLabel, systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(dismissLabel)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        if onBar {
            bar.paneBarBackground()
        } else {
            bar
        }
    }
}

internal extension PaneNoticeBar where Actions == EmptyView {
    init(
        severity: NoticeSeverity,
        alignment: VerticalAlignment = .center,
        onBar: Bool = true,
        dismissLabel: String = String(localized: "Dismiss"),
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            severity: severity,
            alignment: alignment,
            onBar: onBar,
            dismissLabel: dismissLabel,
            onDismiss: onDismiss,
            content: content,
            actions: { EmptyView() }
        )
    }
}

// A title over a secondary detail, the text block every pane notice shows.
internal struct PaneNoticeText: View {
    let title: String
    var detail: String?
    var detailLineLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLineLimit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help(detail)
            }
        }
    }
}

// Copies the notice's text. The pasteboard change is the feedback; VoiceOver hears it said.
internal struct PaneNoticeCopyButton: View {
    let text: String
    let label: String

    var body: some View {
        Button(label, systemImage: "doc.on.doc") {
            ClipboardService.shared.writeText(text)
            AccessibilityAnnouncement.post(String(localized: "Copied to clipboard"))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(label)
    }
}

#Preview {
    VStack(spacing: 0) {
        PaneNoticeBar(severity: .warning, onDismiss: {}) {
            PaneNoticeText(title: "Connected with a warning", detail: "ORA-28002: the password will expire within 7 days")
        } actions: {
            PaneNoticeCopyButton(text: "ORA-28002", label: "Copy Warning")
        }
        Divider()
        PaneNoticeBar(severity: .error, onDismiss: {}) {
            Text("near \"Album\": syntax error")
                .font(.callout)
        } actions: {
            Button("Fix with AI") {}
        }
        Divider()
        Spacer()
    }
    .frame(width: 640, height: 200)
}
