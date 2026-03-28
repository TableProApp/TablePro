//
//  WelcomeConnectionRow.swift
//  TablePro
//

import AppKit
import SwiftUI

struct WelcomeConnectionRow: View {
    let connection: DatabaseConnection
    let sshProfile: SSHProfile?
    var onConnect: (() -> Void)?

    private var displayTag: ConnectionTag? {
        guard let tagId = connection.tagId else { return nil }
        return TagStorage.shared.tag(for: tagId)
    }

    var body: some View {
        HStack(spacing: 12) {
            connection.type.iconImage
                .renderingMode(.template)
                .font(.system(size: ThemeEngine.shared.activeTheme.iconSizes.medium))
                .foregroundStyle(connection.displayColor)
                .frame(
                    width: ThemeEngine.shared.activeTheme.iconSizes.medium,
                    height: ThemeEngine.shared.activeTheme.iconSizes.medium
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.body, weight: .medium))
                        .foregroundStyle(.primary)

                    if let tag = displayTag {
                        Text(tag.name)
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.tiny))
                            .foregroundStyle(tag.color.color)
                            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xxs)
                            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxxs)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    tag.color.color.opacity(0.15)))
                    }
                }

                Text(connectionSubtitle)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView { onConnect?() }
        )
    }

    private var connectionSubtitle: String {
        let ssh = connection.effectiveSSHConfig(profile: sshProfile)
        if ssh.enabled {
            return "SSH : \(ssh.username)@\(ssh.host)"
        }
        if connection.host.isEmpty {
            return connection.database.isEmpty ? connection.type.rawValue : connection.database
        }
        return connection.host
    }
}

private struct DoubleClickView: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughDoubleClickView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? PassThroughDoubleClickView)?.onDoubleClick = onDoubleClick
    }
}

private class PassThroughDoubleClickView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        }
        super.mouseDown(with: event)
    }
}
