import SwiftUI

struct CreateDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let databaseType: DatabaseType
    @ObservedObject var viewModel: DatabaseSwitcherViewModel
    var onCreated: ((String) -> Void)?

    @State private var loadState: LoadState = .loading
    @State private var databaseName = ""
    @State private var values: [String: String] = [:]
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
            Text(String(format: String(localized: "New %@"), containerEntityName))
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var containerEntityName: String {
        PluginManager.shared.containerEntityName(for: databaseType)
    }

    @ViewBuilder
    private var formBody: some View {
        Form {
            TextField(
                String(localized: "Name"),
                text: $databaseName,
                prompt: Text(String(format: String(localized: "%@ name"), containerEntityName))
            )

            switch loadState {
            case .loading:
                loadingRow
            case .ready(let spec):
                CreateDatabaseOptionsView(spec: spec, values: $values)
            case .unsupported:
                Text(String(localized: "This engine does not support creating databases."))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                failureRow(message: message)
            }

            if let errorMessage {
                errorRow(errorMessage)
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
            RevealedTextView(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(String(localized: "Retry")) {
                Task { await load() }
            }
            .controlSize(.small)
        }
    }

    private func errorRow(_ message: String) -> some View {
        Label {
            RevealedTextView(message)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: NoticeSeverity.error.symbolName)
                .foregroundStyle(NoticeSeverity.error.tint)
                .accessibilityHidden(true)
        }
        .font(.callout)
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

    private var canSubmit: Bool {
        guard !databaseName.isEmpty, !isCreating else { return false }
        guard case .ready(let spec) = loadState else { return false }
        return !CreateDatabaseFormRules.missingRequiredInput(in: spec, values: values)
    }

    private func load() async {
        loadState = .loading
        errorMessage = nil
        do {
            guard let spec = try await viewModel.loadCreateDatabaseForm() else {
                loadState = .unsupported
                return
            }
            values = CreateDatabaseFormRules.initialValues(for: spec)
            loadState = .ready(spec)
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        guard case .ready(let spec) = loadState else { return }

        isCreating = true
        errorMessage = nil

        let name = databaseName
        let submissionValues = CreateDatabaseFormRules.submissionValues(from: values, spec: spec)

        Task {
            do {
                try await viewModel.createDatabase(name: name, values: submissionValues)
                onCreated?(name)
                dismiss()
            } catch {
                errorMessage = GatedOperationFailure(error).message
                isCreating = false
            }
        }
    }
}
