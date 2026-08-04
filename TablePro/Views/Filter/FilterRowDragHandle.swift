//
//  FilterRowDragHandle.swift
//  TablePro
//

import SwiftUI

struct FilterRowDragHandle: View {
    static let gutterWidth: CGFloat = 10

    private let dotSize: CGFloat = 2.5
    private let dotSpacing: CGFloat = 2.5
    private let rowCount = 3
    private let columnCount = 2

    var body: some View {
        VStack(spacing: dotSpacing) {
            ForEach(0 ..< rowCount, id: \.self) { _ in
                HStack(spacing: dotSpacing) {
                    ForEach(0 ..< columnCount, id: \.self) { _ in
                        Circle()
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
        .foregroundStyle(.tertiary)
        .frame(width: Self.gutterWidth)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
        .help(String(localized: "Drag to reorder this filter"))
    }
}
