//
//  FilterRowDragHandle.swift
//  TablePro
//

import SwiftUI

struct FilterRowDragHandle: View {
    static let gutterWidth: CGFloat = 12

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .frame(width: Self.gutterWidth)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
            .help(String(localized: "Drag to reorder this filter"))
    }
}
