import SwiftUI

struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseType: DatabaseType
    let viewModel: DatabaseSwitcherViewModel

    @State private var loadState: LoadState = .loading
    @State private var databaseName = ""
    @State private var values: [String: String] = [:]
    @State private var groupSourceFieldIds: Set<String> = []
    @State private var isCreating = false
    @State private var errorMessage: String?

    private enum LoadState {
        case loading
        case ready(CreateDatabaseFormSpec)
        case unsupported
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            formBody
            Divider()
            footer
        }
        .frame(width: 420)
        .onExitCommand {
            if !isCreating {
                dismiss()
            }
        }
        .task { await load() }
    }

    private var header: some View {
        Text(String(localized: "Create Database"))
            .font(.body.weight(.semibold))
            .padding(.vertical, 12)
    }

    private var formBody: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Name")) {
                    TextField(String(localized: "Enter database name"), text: $databaseName)
                }
            }

            switch loadState {
            case .loading:
                Section { loadingView }
            case .ready(let spec):
                Section {
                    fieldsList(spec: spec)
                } footer: {
                    if let footnote = spec.footnote {
                        Text(footnote)
                    }
                }
            case .unsupported:
                Section {
                    Text(String(localized: "This engine does not support creating databases."))
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Section { failureView(message: message) }
            }

            if let error = errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7)
            Text(String(localized: "Loading options..."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func failureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Failed to load options"))
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(String(localized: "Retry")) {
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func fieldsList(spec: CreateDatabaseFormSpec) -> some View {
        ForEach(visibleFields(in: spec)) { field in
            fieldView(field: field, spec: spec)
        }
    }

    private func fieldView(field: CreateDatabaseFormSpec.Field, spec: CreateDatabaseFormSpec) -> some View {
        LabeledContent(field.label) {
            picker(for: field, spec: spec)
                .labelsHidden()
                .pickerStyle(.menu)
        }
    }

    private func picker(for field: CreateDatabaseFormSpec.Field, spec: CreateDatabaseFormSpec) -> some View {
        let binding = Binding<String>(
            get: { values[field.id] ?? "" },
            set: { newValue in
                values[field.id] = newValue
                if groupSourceFieldIds.contains(field.id) {
                    resetGroupedFields(after: field.id, in: spec)
                }
            }
        )
        let options = filteredOptions(for: field)
        return Picker("", selection: binding) {
            ForEach(options, id: \.value) { option in
                Text(displayLabel(for: option)).tag(option.value)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(String(localized: "Cancel")) {
                dismiss()
            }

            Spacer()

            Button(isCreating ? String(localized: "Creating...") : String(localized: "Create")) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSubmit)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(12)
    }

    private var canSubmit: Bool {
        guard !databaseName.isEmpty, !isCreating else { return false }
        if case .ready = loadState { return true }
        return false
    }

    private func visibleFields(in spec: CreateDatabaseFormSpec) -> [CreateDatabaseFormSpec.Field] {
        spec.fields.filter(isVisible(_:))
    }

    private func isVisible(_ field: CreateDatabaseFormSpec.Field) -> Bool {
        guard let visibility = field.visibleWhen else { return true }
        return values[visibility.fieldId] == visibility.equals
    }

    private func filteredOptions(for field: CreateDatabaseFormSpec.Field) -> [CreateDatabaseFormSpec.Option] {
        let allOptions = options(from: field.kind)
        guard allOptions.contains(where: { $0.group != nil }) else { return allOptions }
        guard let sourceId = field.groupedBy,
              let groupValue = values[sourceId] else {
            return allOptions
        }
        return allOptions.filter { $0.group == groupValue }
    }

    private func resetGroupedFields(after sourceId: String, in spec: CreateDatabaseFormSpec) {
        for field in spec.fields where field.groupedBy == sourceId {
            let visible = filteredOptions(for: field).map(\.value)
            if let preferred = defaultValue(from: field.kind), visible.contains(preferred) {
                values[field.id] = preferred
            } else {
                values[field.id] = visible.first ?? ""
            }
        }
    }

    private func options(from kind: CreateDatabaseFormSpec.FieldKind) -> [CreateDatabaseFormSpec.Option] {
        switch kind {
        case .picker(let options, _), .searchable(let options, _):
            return options
        }
    }

    private func defaultValue(from kind: CreateDatabaseFormSpec.FieldKind) -> String? {
        switch kind {
        case .picker(_, let defaultValue), .searchable(_, let defaultValue):
            return defaultValue
        }
    }

    private func displayLabel(for option: CreateDatabaseFormSpec.Option) -> String {
        guard let subtitle = option.subtitle, !subtitle.isEmpty else { return option.label }
        return "\(option.label) \(subtitle)"
    }

    private func load() async {
        loadState = .loading
        errorMessage = nil
        do {
            guard let spec = try await viewModel.loadCreateDatabaseForm() else {
                loadState = .unsupported
                return
            }
            initializeValues(from: spec)
            loadState = .ready(spec)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func initializeValues(from spec: CreateDatabaseFormSpec) {
        var initial: [String: String] = [:]
        var sources: Set<String> = []
        for field in spec.fields {
            let optionValues = options(from: field.kind).map(\.value)
            if let preferred = defaultValue(from: field.kind), optionValues.contains(preferred) {
                initial[field.id] = preferred
            } else if let first = optionValues.first {
                initial[field.id] = first
            }
            if let sourceId = field.groupedBy {
                sources.insert(sourceId)
            }
        }
        values = initial
        groupSourceFieldIds = sources
    }

    private func submit() {
        guard canSubmit else { return }
        guard case .ready(let spec) = loadState else { return }

        isCreating = true
        errorMessage = nil

        let name = databaseName
        let submissionValues = values.filter { entry in
            spec.fields.first { $0.id == entry.key }
                .map { isVisible($0) } ?? false
        }

        Task {
            do {
                try await viewModel.createDatabase(name: name, values: submissionValues)
                await viewModel.refreshDatabases()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
