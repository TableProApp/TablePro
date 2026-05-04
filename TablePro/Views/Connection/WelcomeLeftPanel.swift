//
//  WelcomeLeftPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeLeftPanel: View {
    let onActivateLicense: () -> Void
    let onCreateConnection: () -> Void

    private let updaterBridge = UpdaterBridge.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 4)

                VStack(spacing: 6) {
                    Text("TablePro")
                        .font(.title2.weight(.semibold))

                    versionLine

                    licenseLine
                }
            }

            Spacer()
                .frame(height: 32)

            Button(action: onCreateConnection) {
                Label("Create connection...", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.horizontal, 32)

            Spacer()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    SyncStatusIndicator()
                    KeyboardHint(keys: "⌘N", label: "New")
                    KeyboardHint(keys: "⌘,", label: "Settings")
                }
                HStack(spacing: 8) {
                    SyncStatusIndicator()
                    KeyboardHint(keys: "⌘N", label: "New")
                    KeyboardHint(keys: "⌘,", label: nil)
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .frame(width: 260)
    }

    private var versionLine: some View {
        HStack(spacing: 6) {
            Text("Version \(Bundle.main.appVersion)")
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.tertiary)
            Button {
                updaterBridge.checkForUpdates()
            } label: {
                Text("Check for Updates...")
            }
            .buttonStyle(.link)
            .disabled(!updaterBridge.canCheckForUpdates)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var licenseLine: some View {
        if LicenseManager.shared.status.isValid {
            Label("Pro", systemImage: "checkmark.seal.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(nsColor: .systemGreen))
        } else {
            HoverAccentButton(action: onActivateLicense) {
                Text("Activate License")
                    .font(.subheadline)
            }
        }
    }
}

private struct HoverAccentButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .foregroundStyle(isHovering
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .underline(isHovering, color: .accentColor)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct KeyboardHint: View {
    let keys: String
    let label: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(.caption, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.tertiary.opacity(0.4))
                )
            if let label {
                Text(label)
            }
        }
    }
}
