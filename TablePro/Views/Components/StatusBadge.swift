//
//  StatusBadge.swift
//  TablePro
//

import SwiftUI

/// A short standing label beside a row's title: "Destructive", and whatever joins it.
///
/// Sibling of `TypeBadge`, which says what a column's type is and nothing else. This one carries a
/// tint, because the things worth badging outside a schema are worth colouring. The two share their
/// metrics on purpose, so a window showing both reads as one family.
///
/// The fill is `Color.red.quaternary` rather than an opacity of `.red`. Assistant mode alone had
/// `0.15`, and the rest of the app had `0.08`, `0.16` and `0.18` for the same idea, none of which
/// track the system's contrast settings; the hierarchical style does.
internal struct StatusBadge: View {
    internal enum Tint {
        case neutral
        case destructive
    }

    private let label: String
    private let tint: Tint

    internal init(_ label: String, tint: Tint = .neutral) {
        self.label = label
        self.tint = tint
    }

    internal var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(background, in: Capsule())
            .accessibilityLabel(label)
    }

    private var foreground: AnyShapeStyle {
        switch tint {
        case .neutral: return AnyShapeStyle(.tertiary)
        case .destructive: return AnyShapeStyle(Color.red)
        }
    }

    private var background: AnyShapeStyle {
        switch tint {
        case .neutral: return AnyShapeStyle(.quaternary)
        case .destructive: return AnyShapeStyle(Color.red.quaternary)
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        StatusBadge("Waiting")
        StatusBadge("Destructive", tint: .destructive)
    }
    .padding()
}
