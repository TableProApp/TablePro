//
//  SymbolWell.swift
//  TablePro
//

import SwiftUI
import TableProConnectionLibrary

/// The connection's glyph takes the engine colour until it has a colour of its own, as its tile in
/// the connection list does. A group's glyph takes the group colour, or secondary.
internal struct SymbolWell: View {
    @Binding internal var iconName: String?
    internal let subject: SymbolPickerSubject
    internal let color: ConnectionColor
    internal let accessibilityIdentifier: String

    @State private var isPickerPresented = false

    internal var body: some View {
        Button {
            isPickerPresented = true
        } label: {
            glyph
                .frame(width: 20, height: 16)
        }
        .buttonStyle(.bordered)
        .help(valueDescription)
        .accessibilityLabel(String(localized: "Icon"))
        .accessibilityValue(valueDescription)
        .accessibilityIdentifier(accessibilityIdentifier)
        .popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
            SymbolPickerPopover(selection: iconName, subject: subject) { picked in
                iconName = picked
            }
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch subject {
        case .connection(let type):
            LibraryGlyph.connectionImage(type: type, iconName: iconName)
                .renderingMode(.template)
                .scaledToFit()
                .font(.system(size: 14))
                .foregroundStyle(color.isDefault ? type.themeColor : color.color)
        case .group:
            Image(systemName: LibraryGlyph.groupSymbol(iconName))
                .font(.system(size: 14))
                .foregroundStyle(color.isDefault ? Color.secondary : color.color)
        }
    }

    /// A name the catalog does not list (synced from a newer release) is kept as stored, so it is
    /// described by that name rather than as Default.
    private var valueDescription: String {
        guard let name = LibrarySymbolCatalog.normalizedName(iconName) else {
            return SymbolPickerModel.defaultTitle
        }
        return LibrarySymbolCatalog.symbol(named: name)?.title ?? name
    }
}
