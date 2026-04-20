//
//  DropdownFieldHelper.swift
//  TablePro
//

import SwiftUI

/// Reusable dropdown field wrapper with consistent styling for picker editors.
@MainActor
internal func dropdownField<Content: View>(
    label: String,
    isDisabled: Bool = false,
    @ViewBuilder content: @escaping () -> Content
) -> some View {
    Menu {
        content()
    } label: {
        Text(label)
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .menuIndicator(.hidden)
    .padding(.horizontal, 4)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
    .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
    .disabled(isDisabled)
}
