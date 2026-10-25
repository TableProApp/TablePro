import AppKit
import Combine
import SwiftUI

struct DataGridFindBar: View {
    private struct Capabilities: Equatable {
        var canReplace = false
        var offersSearchAllRows = false
    }

    let model: DataGridModel
    @ObservedObject private var find: GridFindState
    @State private var capabilities = Capabilities()
    @State private var pendingSearch: Task<Void, Never>?
    @State private var status: String?
    @FocusState private var isFindFieldFocused: Bool

    init(model: DataGridModel) {
        self.model = model
        _find = ObservedObject(wrappedValue: model.find)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                findRow
                if find.showsReplace, capabilities.canReplace {
                    replaceRow
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
        }
        .onExitCommand { model.hideFind() }
        .onAppear { isFindFieldFocused = true }
        // Find while the bar is already open moves focus back to its field.
        .onReceive(find.$isVisible.dropFirst()) { isVisible in
            if isVisible { isFindFieldFocused = true }
        }
        // Configuration changes bump this revision; the bar observes nothing else on the model.
        .onReceive(model.$editabilityRevision) { _ in
            capabilities = Capabilities(canReplace: model.canReplaceInFind, offersSearchAllRows: model.offersSearchAllRows)
        }
    }

    // MARK: - Rows

    private var findRow: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Find"), text: termBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 320)
                .focused($isFindFieldFocused)
                .onSubmit { step(forward: NSApp.currentEvent?.modifierFlags.contains(.shift) != true) }
                .accessibilityLabel(String(localized: "Find"))
                .accessibilityIdentifier("grid-find-field")

            optionsMenu

            ControlGroup {
                Button {
                    step(forward: false)
                } label: {
                    Label(String(localized: "Previous match"), systemImage: "chevron.left")
                }
                .help(String(localized: "Previous match"))
                .accessibilityIdentifier("grid-find-previous")

                Button {
                    step(forward: true)
                } label: {
                    Label(String(localized: "Next match"), systemImage: "chevron.right")
                }
                .help(String(localized: "Next match"))
                .accessibilityIdentifier("grid-find-next")
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
            .fixedSize()
            .disabled(find.matches.isEmpty)

            Text(counterText)
                .font(.callout)
                .foregroundStyle(find.problem == nil || status != nil ? Color.secondary : Color(nsColor: .systemRed))
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityLabel(counterText)
                .accessibilityIdentifier("grid-find-count")

            scopeButton

            Spacer(minLength: 8)

            if showsSearchAllRows {
                Button(String(localized: "Search All Rows")) { model.searchAllRows() }
                    .accessibilityIdentifier("grid-find-search-all-rows")
            }

            if capabilities.canReplace {
                Toggle(String(localized: "Replace"), isOn: $find.showsReplace)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("grid-find-replace-toggle")
            }

            Button(String(localized: "Done")) { model.hideFind() }
                .accessibilityIdentifier("grid-find-done")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Replace with"), text: $find.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 320)
                .accessibilityLabel(String(localized: "Replace with"))
                .accessibilityIdentifier("grid-replace-field")

            Button(String(localized: "Replace")) { replaceCurrent() }
                .disabled(!model.canReplaceCurrentFindMatch)
                .accessibilityIdentifier("grid-replace")

            Button(String(localized: "Replace All")) { replaceAll() }
                .disabled(find.matches.isEmpty || find.problem != nil)
                .accessibilityIdentifier("grid-replace-all")

            Spacer()
        }
    }

    private var optionsMenu: some View {
        Menu {
            Toggle(String(localized: "Match Case"), isOn: option(\.matchesCase))
            Toggle(String(localized: "Whole Words"), isOn: option(\.matchesWholeWord))
            Toggle(String(localized: "Regular Expression"), isOn: option(\.usesRegularExpression))
            Divider()
            Picker(String(localized: "Search In"), selection: scopeBinding) {
                Text(String(localized: "All Columns")).tag(DataGridColumnID?.none)
                ForEach(model.columns.columns, id: \.id) { column in
                    Text(column.name).tag(DataGridColumnID?.some(column.id))
                }
            }
        } label: {
            Label(String(localized: "Find Options"), systemImage: "slider.horizontal.3")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .help(String(localized: "Find Options"))
        .accessibilityLabel(String(localized: "Find Options"))
        .accessibilityIdentifier("grid-find-options")
    }

    @ViewBuilder
    private var scopeButton: some View {
        if let scope = find.options.columnScope, let column = model.columns.column(id: scope) {
            Button {
                setScope(nil)
            } label: {
                Label(String(format: String(localized: "In column %@"), column.name), systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Search every column"))
        }
    }

    // MARK: - State

    private var counterText: String {
        if let status { return status }
        if let problem = find.problem { return problem }
        guard model.hasFindTerm else { return "" }
        // A search that refreshes keeps showing the count it is about to replace.
        if find.matches.isEmpty {
            if find.isSearching { return String(localized: "Searching…") }
            if find.searchStopped { return String(localized: "Search stopped") }
        }
        return FindCounterText.text(
            matchCount: find.matches.count,
            currentIndex: find.currentIndex,
            scope: model.findCoversPageOnly ? .pageOfMore : .allRowsLoaded
        )
    }

    // Only when this page has no match, so the bar stays short while matches are on screen.
    private var showsSearchAllRows: Bool {
        capabilities.offersSearchAllRows && model.searchAllRowsKeepsTheOptions && model.hasFindTerm
            && find.problem == nil && find.matches.isEmpty
    }

    // Use Selection for Find searches on its own, so only typing goes through the delay.
    private var termBinding: Binding<String> {
        Binding(
            get: { find.term },
            set: { newValue in
                guard newValue != find.term else { return }
                find.term = newValue
                status = nil
                scheduleSearch()
            }
        )
    }

    private var scopeBinding: Binding<DataGridColumnID?> {
        Binding(
            get: { find.options.columnScope },
            set: { setScope($0) }
        )
    }

    private func option(_ keyPath: WritableKeyPath<GridFindState.Options, Bool>) -> Binding<Bool> {
        Binding(
            get: { find.options[keyPath: keyPath] },
            set: { newValue in
                find.options[keyPath: keyPath] = newValue
                searchNow()
            }
        )
    }

    // MARK: - Actions

    private func setScope(_ scope: DataGridColumnID?) {
        find.options.columnScope = scope
        searchNow()
    }

    // One scan per pause in typing, not per key: a wide page is hundreds of thousands of cells.
    private func scheduleSearch() {
        pendingSearch?.cancel()
        pendingSearch = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            pendingSearch = nil
            model.findQueryDidChange()
        }
    }

    private func searchNow() {
        pendingSearch?.cancel()
        pendingSearch = nil
        status = nil
        model.findQueryDidChange()
    }

    // A search still waiting on the delay already lands on the first match from the cursor.
    private func step(forward: Bool) {
        status = nil
        if pendingSearch != nil {
            searchNow()
            if forward { return }
        }
        if forward {
            model.findNext()
        } else {
            model.findPrevious()
        }
    }

    private func replaceCurrent() {
        if pendingSearch != nil {
            searchNow()
        }
        status = nil
        model.replaceCurrentMatch()
    }

    // A dataset finder reports its outcome in its own window, so nothing comes back here.
    private func replaceAll() {
        pendingSearch?.cancel()
        pendingSearch = nil
        status = nil
        guard let outcome = model.replaceAllMatches() else { return }
        status = GridFindEngine.replacementMessage(replacements: outcome.replacements, cells: outcome.cells)
    }
}
