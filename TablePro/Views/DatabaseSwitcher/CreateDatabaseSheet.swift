import SwiftUI

struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseType: DatabaseType
    let viewModel: DatabaseSwitcherViewModel
    var onCreated: ((String) -> Void)?

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
        VStack(alignment: .leading, spacing: 0) {
            titleRow

            Divider()

            formBody
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            if let error = errorMessage {
                Divider()
                errorBanner(error)
            }

            Divider()

            buttonBar
        }
        .frame(width: 380)
        .onExitCommand {
            if !isCreating { dismiss() }
        }
        .task { await load() }
    }

    private var titleRow: some View {
        HStack {
            Text(String(localized: "New Database"))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var formBody: some View {
        Form {
            TextField(
                String(localized: "Name"),
                text: $databaseName,
                prompt: Text(String(localized: "Database name"))
            )

            switch loadState {
            case .loading:
                loadingRow
            case .ready(let spec):
                fieldsList(spec: spec)
                if let footnote = spec.footnote {
                    Text(footnote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .unsupported:
                Text(String(localized: "This engine does not support creating databases."))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                failureRow(message: message)
            }
        }
        .formStyle(.columns)
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(String(localized: "Loading options…"))
                .foregroundStyle(.secondary)
        }
    }

    private func failureRow(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Failed to load options"))
                .font(.body.weight(.medium))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "Retry")) {
                Task { await load() }
            }
            .controlSize(.small)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var buttonBar: some View {
        HStack {
            Spacer()

            Button(String(localized: "Cancel")) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(String(localized: "Create")) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func fieldsList(spec: CreateDatabaseFormSpec) -> some View {
        ForEach(visibleFields(in: spec)) { field in
            fieldRow(field: field, spec: spec)
        }
    }

    private func fieldRow(field: CreateDatabaseFormSpec.Field, spec: CreateDatabaseFormSpec) -> some View {
        picker(for: field, spec: spec)
            .pickerStyle(.menu)
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
        return Picker(field.label, selection: binding) {
            ForEach(options, id: \.value) { option in
                Text(displayLabel(for: option)).tag(option.value)
            }
        }
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
                onCreated?(name)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
