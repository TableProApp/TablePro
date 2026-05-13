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

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
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
