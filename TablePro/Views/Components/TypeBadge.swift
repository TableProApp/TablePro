//
//  TypeBadge.swift
//  TablePro
//

import SwiftUI

struct TypeBadge: View {
    let label: String
    let accessibilityDescription: String?

    init(_ label: String, accessibilityDescription: String? = nil) {
        self.label = label
        self.accessibilityDescription = accessibilityDescription
    }

    /// The badge keeps its one line and its measured width whatever it is put next to. Without this
    /// a compressed `HStack` wraps the text inside the capsule instead of giving way: at the
    /// inspector's 270pt minimum, a long column name squeezed "date" into "dat" over "e" and grew
    /// the row by 11pt.
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel(Text("Type: \(accessibilityDescription ?? label)"))
    }
}

#Preview {
    VStack(spacing: 8) {
        TypeBadge("INT")
        TypeBadge("VARCHAR", accessibilityDescription: "VARCHAR(255)")
        TypeBadge("TIMESTAMP")
    }
    .padding()
}
