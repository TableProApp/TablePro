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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tag.color.color, in: Capsule())
            .padding(.leading, 8)
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
