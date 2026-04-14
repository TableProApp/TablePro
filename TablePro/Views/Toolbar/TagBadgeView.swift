//
//  TagBadgeView.swift
//  TablePro
//
//  Tag badge for toolbar display showing connection environment.
//  Uses capsule background with colored text matching tag color.
//

import SwiftUI

/// Compact badge showing the connection's tag with capsule background
struct TagBadgeView: View {
    let tag: ConnectionTag

    /// Display name with validation for empty/whitespace tags
    private var displayName: String {
        let trimmed = tag.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "UNTAGGED" : trimmed.uppercased()
    }

    var body: some View {
        Text(displayName)
            .font(.system(size: ThemeEngine.shared.activeTheme.typography.small, weight: .medium))
            .foregroundStyle(tag.color.color)
            .lineLimit(1)  // Prevent overflow from very long tag names
            .padding(.horizontal, ThemeEngine.shared.activeTheme.spacing.xs)
            .padding(.vertical, ThemeEngine.shared.activeTheme.spacing.xxs)
            .background(
                Capsule()
                    .fill(tag.color.color.opacity(0.2))
            )
            .padding(.leading, ThemeEngine.shared.activeTheme.spacing.xs)
            .help(String(format: String(localized: "Tag: %@"), tag.name))
            .accessibilityLabel(String(format: String(localized: "Tag: %@"), tag.name))
    }
}

// MARK: - Preview

#Preview("Tag Badges") {
    VStack(spacing: 12) {
        TagBadgeView(tag: ConnectionTag(name: "local", isPreset: true, color: .green))
        TagBadgeView(tag: ConnectionTag(name: "production", isPreset: true, color: .red))
        TagBadgeView(tag: ConnectionTag(name: "development", isPreset: true, color: .blue))
        TagBadgeView(tag: ConnectionTag(name: "testing", isPreset: true, color: .orange))
    }
    .padding()
    .background(Color(nsColor: .windowBackgroundColor))
}
