import SwiftUI
import TableProPluginKit

struct KeyPatternSearchBar: View {
    let coordinator: MainContentCoordinator
    let descriptor: BrowseFilterDescriptor

    @State private var pattern: String = ""
    @State private var typeScope: String?

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
                .fixedSize()
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
