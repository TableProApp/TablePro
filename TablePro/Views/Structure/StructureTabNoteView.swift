//
//  StructureTabNoteView.swift
//  TablePro
//

import SwiftUI

struct StructureTabNoteView: View {
    let systemImage: String
    let text: String
    let identifier: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Label(text, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .accessibilityIdentifier(identifier)
        }
    }
}
