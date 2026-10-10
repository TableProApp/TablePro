import SwiftUI
import TableProConnectionLibrary
import TableProModels

nonisolated enum SymbolPickerSubject: Hashable, Sendable {
    case connection(DatabaseType)
    case group(ConnectionColor)

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

struct SymbolPickerRow: View {
    @Binding var selection: String?
    let subject: SymbolPickerSubject

    @ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 18

    var body: some View {
        NavigationLink {
            SymbolPickerView(selection: $selection, subject: subject)
        } label: {
            LabeledContent {
                preview
                    .accessibilityHidden(true)
            } label: {
                Text("Icon")
            }
        }
        .accessibilityValue(Text(LibraryGlyph.title(for: selection)))
    }

    @ViewBuilder
    private var preview: some View {
        switch subject {
        case .connection(let type):
            DatabaseIconView(type: type, iconName: selection, size: glyphSize)
        case .group(let color):
            Image(systemName: LibraryGlyph.groupSymbol(selection))
                .font(.system(size: glyphSize))
                .foregroundStyle(color == .none ? Color.secondary : ConnectionColorPicker.swiftUIColor(for: color))
        }
    }
}

struct SymbolPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: String?
    let subject: SymbolPickerSubject

    @State private var query = ""
    @ScaledMetric(relativeTo: .title3) private var glyphSize: CGFloat = 20

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        let sections = LibrarySymbolCatalog.sections(matching: query)
        let showsDefault = Self.defaultMatches(query)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8, pinnedViews: [.sectionHeaders]) {
                    if showsDefault {
                        Section {
                            defaultCell
                        }
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.symbols) { symbol in
                                cell(for: symbol)
                            }
                        } header: {
                            Text(section.category.title)
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                                .background(.background)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .onAppear {
                guard let selection, LibrarySymbolCatalog.symbol(named: selection) != nil else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
        }
        .overlay {
            if sections.isEmpty, !showsDefault {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search Icons"))
        .navigationTitle(Text("Icon"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var defaultCell: some View {
        let isSelected = selection == nil
        return Button {
            pick(nil)
        } label: {
            defaultGlyph(tint: isSelected ? Color.accentColor : Color.primary)
                .modifier(SymbolCellStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel(Text("Default"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func defaultGlyph(tint: Color) -> some View {
        switch subject {
        case .connection(let type):
            DatabaseIconView(type: type, size: glyphSize, tint: tint)
        case .group:
            Image(systemName: LibraryGlyph.groupSymbol(nil))
                .font(.system(size: glyphSize))
                .foregroundStyle(tint)
        }
    }

    private func cell(for symbol: LibrarySymbol) -> some View {
        let isSelected = selection == symbol.name
        return Button {
            pick(symbol.name)
        } label: {
            Image(systemName: subject.isGroup ? LibraryGlyph.filledVariant(of: symbol.name) : symbol.name)
                .font(.system(size: glyphSize))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .modifier(SymbolCellStyle(isSelected: isSelected))
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel(Text(symbol.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pick(_ name: String?) {
        selection = name
        dismiss()
    }

    private static func defaultMatches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || String(localized: "Default").localizedStandardContains(term)
    }
}

private struct SymbolCellStyle: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return content
            .frame(maxWidth: .infinity, minHeight: 44)
            .background {
                if isSelected {
                    shape.fill(Color.accentColor.opacity(0.15))
                }
            }
            .contentShape(shape)
    }
}
