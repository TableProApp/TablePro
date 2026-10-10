//
//  SymbolPickerPopover.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProConnectionLibrary

internal enum SymbolPickerSubject: Equatable {
    case connection(DatabaseType)
    case group
}

/// Picking commits and closes, the way a popover closes when an item in it is chosen.
internal struct SymbolPickerPopover: View {
    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: SymbolPickerModel.columnCount)

    @Environment(\.dismiss) private var dismiss
    @State private var model: SymbolPickerModel
    private let subject: SymbolPickerSubject
    private let onPick: (String?) -> Void

    internal init(selection: String?, subject: SymbolPickerSubject, onPick: @escaping (String?) -> Void) {
        _model = State(initialValue: SymbolPickerModel(selection: selection))
        self.subject = subject
        self.onPick = onPick
    }

    internal var body: some View {
        VStack(spacing: 0) {
            /// The field editor consumes the arrow keys before `onMoveCommand` sees them, so the
            /// search field's own delegate hands them over. Escape clears a non-empty field there
            /// and reaches `onExitCommand` only once the field is empty.
            NativeSearchField(
                text: $model.query,
                placeholder: String(localized: "Search Icons"),
                onMoveUp: { model.moveUp() },
                onMoveDown: { model.moveDown() },
                onSubmit: commitHighlight,
                focusOnAppear: true,
                accessibilityIdentifier: "symbol-picker-search"
            )
            .padding(10)

            Divider()

            if model.isEmpty {
                UnavailableStateView.search(text: model.query)
            } else {
                grid
            }
        }
        .frame(width: 300, height: 360)
        .onExitCommand { dismiss() }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4, pinnedViews: [.sectionHeaders]) {
                    if model.showsDefault {
                        Section {
                            defaultCell
                        }
                    }
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.symbols) { symbol in
                                symbolCell(symbol)
                            }
                        } header: {
                            SymbolPickerSectionHeader(title: section.category.title)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onAppear { scrollToHighlight(proxy, anchor: .center) }
            .onChange(of: model.highlight) { _ in scrollToHighlight(proxy, anchor: nil) }
        }
    }

    private var defaultCell: some View {
        SymbolPickerCell(
            title: SymbolPickerModel.defaultTitle,
            help: defaultHelp,
            isHighlighted: model.highlight == .defaultIcon,
            isSelected: model.isSelected(.defaultIcon),
            accessibilityIdentifier: "symbol-picker-default",
            action: { commit(.defaultIcon) },
            glyph: { defaultGlyph }
        )
        .id(SymbolPickerItem.defaultIcon)
    }

    private func symbolCell(_ symbol: LibrarySymbol) -> some View {
        let item = SymbolPickerItem.symbol(symbol.name)
        return SymbolPickerCell(
            title: symbol.title,
            help: symbol.title,
            isHighlighted: model.highlight == item,
            isSelected: model.isSelected(item),
            accessibilityIdentifier: "symbol-picker-\(symbol.name)",
            action: { commit(item) },
            glyph: { Image(systemName: glyphName(for: symbol.name)) }
        )
        .id(item)
    }

    @ViewBuilder
    private var defaultGlyph: some View {
        switch subject {
        case .connection(let type):
            LibraryGlyph.connectionImage(type: type, iconName: nil)
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 18, height: 18)
        case .group:
            Image(systemName: LibraryGlyph.groupSymbol(nil))
        }
    }

    private var defaultHelp: String {
        switch subject {
        case .connection(let type):
            return String(format: String(localized: "Default (%@)"), type.rawValue)
        case .group:
            return SymbolPickerModel.defaultTitle
        }
    }

    /// A group draws the filled variant wherever it appears, so its picker shows the same shape.
    private func glyphName(for name: String) -> String {
        switch subject {
        case .connection: return name
        case .group: return SymbolPickerGroupGlyphs.glyph(for: name)
        }
    }

    private func commitHighlight() {
        guard let item = model.commit() else { return }
        commit(item)
    }

    private func commit(_ item: SymbolPickerItem) {
        onPick(item.iconName)
        dismiss()
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy, anchor: UnitPoint?) {
        guard let highlight = model.highlight else { return }
        proxy.scrollTo(highlight, anchor: anchor)
    }
}

/// Each lookup asks AppKit whether a fill variant exists, and the grid redraws every visible cell
/// on each arrow key.
@MainActor
private enum SymbolPickerGroupGlyphs {
    private static var cache: [String: String] = [:]

    static func glyph(for name: String) -> String {
        if let cached = cache[name] { return cached }
        let glyph = LibraryGlyph.groupSymbol(name)
        cache[name] = glyph
        return glyph
    }
}

private struct SymbolPickerSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .background(.regularMaterial)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SymbolPickerCell<Glyph: View>: View {
    let title: String
    let help: String
    let isHighlighted: Bool
    let isSelected: Bool
    let accessibilityIdentifier: String
    let action: () -> Void
    @ViewBuilder let glyph: () -> Glyph

    var body: some View {
        Button(action: action) {
            glyph()
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17))
                .foregroundStyle(isHighlighted ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(SymbolPickerCellStyle(isHighlighted: isHighlighted))
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// The highlight uses the pair AppKit documents for selected content in a collection, so it
/// follows the accent colour and keeps its contrast. Hover is the swatch palette's quaternary fill.
private struct SymbolPickerCellStyle: ButtonStyle {
    let isHighlighted: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fill(isPressed: configuration.isPressed))
            }
            .onHover { isHovering = $0 }
    }

    private func fill(isPressed: Bool) -> Color {
        if isHighlighted { return Color(nsColor: .selectedContentBackgroundColor) }
        return isPressed || isHovering ? Color(nsColor: .quaternaryFill) : .clear
    }
}
