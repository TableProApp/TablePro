//
//  AboutView.swift
//  TablePro
//
//  Custom About window view with app info and links.
//

import AppKit
import SwiftUI

struct AboutView: View {
    @State private var hoveredLink: String?

    var body: some View {
        VStack(spacing: ThemeEngine.shared.activeTheme.spacing.md) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            VStack(spacing: ThemeEngine.shared.activeTheme.spacing.xxs) {
                Text("TablePro")
                    .font(
                        .system(
                            size: ThemeEngine.shared.activeTheme.iconSizes.extraLarge, weight: .semibold,
                            design: .rounded))

                Text("Version \(Bundle.main.appVersion) (Build \(Bundle.main.buildNumber))")
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.medium))
                    .foregroundStyle(.secondary)
            }

            Text("© 2026 Ngo Quoc Dat.\n\(String(localized: "All rights reserved."))")
                .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: ThemeEngine.shared.activeTheme.spacing.lg) {
                linkButton(
                    title: String(localized: "Website"),
                    icon: "globe",
                    url: "https://tablepro.app"
                )
                linkButton(
                    title: "GitHub",
                    icon: "chevron.left.forwardslash.chevron.right",
                    url: "https://github.com/datlechin/TablePro"
                )
                linkButton(
                    title: String(localized: "Documentation"),
                    icon: "book",
                    url: "https://docs.tablepro.app"
                )
                linkButton(
                    title: String(localized: "Sponsor"),
                    icon: "heart",
                    url: "https://github.com/sponsors/datlechin"
                )
            }

            Spacer()
        }
        .frame(width: 300, height: 320)
    }

    private func linkButton(title: String, icon: String, url: String) -> some View {
        Button {
            if let link = URL(string: url) {
                NSWorkspace.shared.open(link)
            }
        } label: {
            VStack(spacing: ThemeEngine.shared.activeTheme.spacing.xxxs) {
                Image(systemName: icon)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.body))
                Text(title)
                    .font(.system(size: ThemeEngine.shared.activeTheme.typography.small))
                    .underline(hoveredLink == title)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredLink = isHovered ? title : nil
        }
    }
}
