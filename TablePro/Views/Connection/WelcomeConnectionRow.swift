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
                .font(.system(size: 16))
                .foregroundStyle(connection.displayColor)
                .frame(
                    width: 16,
                    height: 16
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    if let tag = displayTag {
                        Text(tag.name)
                            .font(.system(size: 9))
                            .foregroundStyle(tag.color.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(
                                    tag.color.color.opacity(0.15)))
                    }
                }

                Text(connectionSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(connectionSubtitle)
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .overlay(
            DoubleClickView { onConnect?() }
        )
    }

    private var connectionSubtitle: String {
        let ssh = connection.resolvedSSHConfig
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
