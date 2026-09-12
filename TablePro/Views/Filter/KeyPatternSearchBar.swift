import SwiftUI
import TableProPluginKit

struct KeyPatternSearchBar: View {
    let coordinator: MainContentCoordinator
    let descriptor: BrowseFilterDescriptor

    @State private var pattern: String = ""
    @State private var typeScope: String?

    /// How much of a type name the bar will spend width on before truncating it.
    private static let typeScopeMaximumWidth: CGFloat = 160

    var body: some View {
        HStack(spacing: 8) {
            NativeSearchField(
                text: $pattern,
                placeholder: placeholder,
                controlSize: .regular,
                onSubmit: apply
            )
            .frame(maxWidth: 360)

            if !descriptor.typeScopes.isEmpty {
                Picker(String(localized: "Type"), selection: $typeScope) {
                    Text("All Types").tag(String?.none)
                    ForEach(descriptor.typeScopes) { scope in
                        Text(scope.label).tag(String?.some(scope.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                /// Bounded rather than `.fixedSize()`, for the reason `FilterRowView`'s column
                /// pull-down is: the items are driver-supplied type names, and a pull-down takes the
                /// width of its widest one, so an unbounded one could make this bar wider than the
                /// pane and clip the grid beside it.
                .frame(maxWidth: Self.typeScopeMaximumWidth)
                .onChange(of: typeScope) { _, _ in apply() }
            }

            if isActive {
                Button(String(localized: "Clear"), action: clear)
                    .buttonStyle(.borderless)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear(perform: syncFromState)
        .onChange(of: coordinator.selectedTabFilterState.browseSearch) { _, _ in
            syncFromState()
        }
    }

    private var isActive: Bool {
        BrowseSearchState(pattern: pattern, typeScope: typeScope).isActive
    }

    private var placeholder: String {
        descriptor.usesGlob
            ? String(localized: "Key pattern, e.g. user:*")
            : String(localized: "Key pattern")
    }

    private func syncFromState() {
        let search = coordinator.selectedTabFilterState.browseSearch
        pattern = search.pattern
        typeScope = search.typeScope
    }

    private func apply() {
        coordinator.applyBrowseSearch(BrowseSearchState(pattern: pattern, typeScope: typeScope))
    }

    private func clear() {
        pattern = ""
        typeScope = nil
        coordinator.clearBrowseSearchAndReload()
    }
}
