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

    // Fixed width: at the inspector's 270pt minimum a compressed HStack wrapped "date" over two lines.
    var body: some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
