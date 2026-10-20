import SwiftUI
import TableProTabularIO

struct JSONValueEditorSheet: View {
    let title: String
    let onDone: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var caretRequest: JSONTextView.CaretRequest?
    private let original: String

    init(title: String, text: String, onDone: @escaping (String) -> Void) {
        self.title = title
        self.onDone = onDone
        self.original = text
        _draft = State(initialValue: text)
    }

    private var hasChanges: Bool { draft != original }

    var body: some View {
        let failure = Self.failure(of: draft)
        NavigationStack {
            JSONTextView(text: $draft, caretRequest: caretRequest)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let failure {
                        errorLine(failure)
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        DiscardChangesCancelButton(hasChanges: hasChanges) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        ConfirmButton(title: "Done", action: finish)
                            .disabled(failure != nil)
                    }
                    ToolbarItem(placement: .bottomBar) {
                        Button("Format", action: format)
                            .disabled(draft.isEmpty || failure != nil)
                    }
                }
        }
        .presentationSizing(.page)
        .interactiveDismissDisabled(hasChanges)
        .holdsScene(withUnsavedChanges: hasChanges)
    }

    private func errorLine(_ failure: JSONValidation.Failure) -> some View {
        Button {
            showError(failure)
        } label: {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(.bar)
        .accessibilityHint("Moves the cursor to the error.")
    }

    // Empty text is not checked: the row's NULL rule decides what an empty value saves.
    private static func failure(of text: String) -> JSONValidation.Failure? {
        guard !text.isEmpty, case .failure(let failure) = JSONValidation.check(text) else { return nil }
        return failure
    }

    private func showError(_ failure: JSONValidation.Failure) {
        caretRequest = JSONTextView.CaretRequest(
            utf16Offset: failure.utf16Offset,
            serial: (caretRequest?.serial ?? 0) + 1
        )
    }

    private func format() {
        guard let pretty = JSONPrettyPrinter.format(draft) else { return }
        draft = pretty
    }

    private func finish() {
        onDone(draft)
        dismiss()
    }
}
