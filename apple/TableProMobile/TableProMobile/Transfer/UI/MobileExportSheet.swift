import SwiftUI
import TableProPluginKit

struct MobileExportItem: Identifiable {
    let id = UUID()
    let input: MobileExportInput
}

// Format, scope, options, generate, then the share sheet: the order Numbers follows for Export.
struct MobileExportSheet: View {
    @State private var model: MobileExportModel
    @Environment(\.dismiss) private var dismiss

    init(input: MobileExportInput, environment: MobileExportEnvironment) {
        _model = State(initialValue: MobileExportModel(input: input, environment: environment))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(Text(verbatim: model.input.title))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .interactiveDismissDisabled(model.isRunning)
        .task { await model.loadObjectsIfNeeded() }
        .onDisappear { model.close() }
        .sheet(isPresented: sharing, onDismiss: { model.shareEnded() }) {
            ActivityViewController(items: model.finished?.files ?? [])
        }
    }

    private var sharing: Binding<Bool> {
        Binding(
            get: { model.phase == .sharing },
            set: { if !$0 { model.shareEnded() } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .configuring:
            configuration
        case .running(let progress):
            Form {
                TransferProgressSection(progress: progress)
            }
        case .sharing:
            Form {
                Section {
                    Label("Ready to Share", systemImage: "checkmark.circle")
                }
            }
        case .finished:
            finishedView
        case .failed(let message):
            Form {
                Section {
                    Label {
                        Text(verbatim: message)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Export Failed")
                }
                Section {
                    Button("Try Again") { model.reconfigure() }
                }
            }
        case .cancelled:
            Form {
                Section {
                    Text("The export was cancelled. No file was kept.")
                }
                Section {
                    Button("Change Options") { model.reconfigure() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        switch model.phase {
        case .configuring:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Export") { model.start() }
                    .disabled(!model.canExport)
            }
        case .running:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { model.cancel() }
            }
        case .sharing, .finished, .failed, .cancelled:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Configuring

    private var configuration: some View {
        @Bindable var model = model
        return Form {
            Section {
                Picker("Format", selection: Binding(get: { model.formatId }, set: { model.selectFormat($0) })) {
                    ForEach(model.formatChoices) { choice in
                        Text(verbatim: choice.name).tag(choice.id)
                    }
                }
                .pickerStyle(.menu)
                LabeledContent("File Name") {
                    LiteralTextField("File Name", text: $model.fileName)
                }
            } footer: {
                if let plugin = model.plugin {
                    Text(verbatim: ".\(plugin.currentFileExtension)")
                }
            }
            scopeSection
            if model.scope?.listsObjects == true {
                ExportObjectsSections(model: model)
            }
            if let plugin = model.plugin {
                ExportFormatOptionsSection(plugin: plugin)
            }
        }
    }

    @ViewBuilder
    private var scopeSection: some View {
        let scopes = model.input.scopes
        if scopes.count > 1 {
            Section {
                Picker("Export", selection: Binding(
                    get: { model.scopeKind },
                    set: { kind in Task { await model.selectScope(kind) } }
                )) {
                    ForEach(scopes) { scope in
                        Text(verbatim: scope.title).tag(scope.kind)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Export")
            } footer: {
                if let detail = model.scope?.detail {
                    Text(verbatim: detail)
                }
            }
        } else if let detail = model.scope?.detail {
            Section {
                Text(verbatim: detail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Finished

    private var finishedView: some View {
        Form {
            if let finished = model.finished {
                Section {
                    Label {
                        Text(verbatim: String(
                            format: String(localized: "%@ rows written."), finished.rowsWritten.formatted()
                        ))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    ForEach(finished.files, id: \.self) { file in
                        Text(verbatim: file.lastPathComponent)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if !finished.warnings.isEmpty {
                    Section {
                        ForEach(finished.warnings, id: \.self) { warning in
                            Label {
                                Text(verbatim: warning)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                            }
                        }
                    } header: {
                        Text("Warnings")
                    }
                }
                if !finished.notes.isEmpty {
                    Section {
                        ForEach(finished.notes, id: \.self) { note in
                            Text(verbatim: note)
                        }
                    }
                }
                Section {
                    ShareLink(items: finished.files) {
                        Label("Share Again", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// One section per object kind, with Select All for the kind and the format's per-object options in a menu.
private struct ExportObjectsSections: View {
    let model: MobileExportModel

    var body: some View {
        switch model.objects {
        case .some(.loading), .none:
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Reading objects…")
                        .foregroundStyle(.secondary)
                }
            }
        case .some(.failed(let error)):
            Section {
                Text(verbatim: error.localizedDescription)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await model.retryObjects() } }
            } header: {
                Text("Objects")
            }
        case .some(.loaded):
            let groups = model.objectGroups
            if groups.isEmpty {
                Section {
                    Text("Nothing here can be exported in this format.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.rows) { row in
                        ExportObjectRowView(model: model, row: row)
                    }
                } header: {
                    groupHeader(group.kind, rows: group.rows, offersSelectAll: groups.count > 1 || group.rows.count > 1)
                }
            }
        }
    }

    private func groupHeader(_ kind: PluginExportObjectKind, rows: [ExportObjectRow], offersSelectAll: Bool) -> some View {
        let allSelected = rows.allSatisfy(\.isSelected)
        return HStack {
            Text(verbatim: ExportObjectKindLabel.title(for: kind))
            Spacer()
            if offersSelectAll {
                Button(allSelected ? String(localized: "Deselect All") : String(localized: "Select All")) {
                    model.setSelected(!allSelected, kind: kind)
                }
                .font(.footnote)
                .textCase(nil)
            }
        }
    }
}

private struct ExportObjectRowView: View {
    let model: MobileExportModel
    let row: ExportObjectRow

    private var columns: [PluginExportOptionColumn] { model.optionColumns }

    private var supportedColumns: [Int] {
        guard let plugin = model.plugin else { return [] }
        return columns.indices.filter { index in
            row.object.optionValues.indices.contains(index)
                && type(of: plugin).supportsOption(columnId: columns[index].id, for: row.object.kind)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.setSelected(!row.isSelected, for: row.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                        .imageScale(.large)
                        .foregroundStyle(row.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Image(systemName: ExportObjectKindLabel.systemImage(for: row.object.kind))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.object.name)
                            .foregroundStyle(.primary)
                        if let parent = row.object.parentTable, !parent.isEmpty {
                            Text(verbatim: parent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(row.isSelected ? .isSelected : [])
            Spacer(minLength: 0)
            if row.isSelected, !supportedColumns.isEmpty {
                optionsMenu
            }
        }
    }

    private var optionsMenu: some View {
        Menu {
            ForEach(supportedColumns, id: \.self) { index in
                Toggle(isOn: Binding(
                    get: { row.object.optionValues.indices.contains(index) && row.object.optionValues[index] },
                    set: { model.setOption($0, at: index, for: row.id) }
                )) {
                    Text(verbatim: columns[index].label)
                }
            }
        } label: {
            Text(verbatim: optionSummary)
                .font(.footnote)
                .lineLimit(1)
        }
        .accessibilityLabel(Text("Options"))
        .accessibilityValue(Text(verbatim: optionSummary))
    }

    private var optionSummary: String {
        let enabled = supportedColumns
            .filter { row.object.optionValues[$0] }
            .map { columns[$0].label }
        guard !enabled.isEmpty else { return String(localized: "None") }
        return ListFormatter.localizedString(byJoining: enabled)
    }
}
