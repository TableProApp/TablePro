//
//  WelcomeLeftPanel.swift
//  TablePro
//

import SwiftUI

struct WelcomeLeftPanel: View {
    let onActivateLicense: () -> Void
    let onCreateConnection: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 20, x: 0, y: 0)

                VStack(spacing: 6) {
                    Text("TablePro")
                        .font(
                            .system(
                                size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge, weight: .semibold,
                                design: .rounded))

                    Text("Version \(Bundle.main.appVersion)")
                        .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                        .foregroundStyle(.secondary)

                    if LicenseManager.shared.status.isValid {
                        Label("Pro", systemImage: "checkmark.seal.fill")
                            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Button(action: onActivateLicense) {
                            Text("Activate License")
                                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
                .frame(height: 48)

            VStack(spacing: 12) {
                Button {
                    if let url = URL(string: "https://github.com/sponsors/datlechin") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Sponsor TablePro", systemImage: "heart")
                }
                .buttonStyle(.plain)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.pink)

                Button(action: onCreateConnection) {
                    Label("Create connection...", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WelcomeButtonStyle())
            }
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
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.sm)
            .padding(.bottom, ThemeEngine.shared.activeTheme.spacing.lg)
        }
        .frame(width: 260)
    }
}

struct WelcomeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
            .foregroundStyle(.primary)
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.md)
            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        Color(
                            nsColor: configuration.isPressed
                                ? .controlBackgroundColor : .quaternaryLabelColor))
            )
    }
}

struct KeyboardHint: View {
    let keys: String
    let label: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.caption, design: .monospaced))
                .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xxs + 1)
                .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxxs)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                )
            if let label {
                Text(label)
            }
        }
    }
}
