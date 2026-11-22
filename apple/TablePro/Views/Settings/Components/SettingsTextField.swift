import SwiftUI

struct SettingsTextField: View {
    private let title: LocalizedStringKey
    private let subtitle: LocalizedStringKey?
    @Binding private var text: String
    private let prompt: Text?
    private let validate: (String) -> String?
    private let normalize: (String) -> String

    @State private var draft: SettingsTextDraft
    @FocusState private var isFocused: Bool

    init(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        text: Binding<String>,
        prompt: Text? = nil,
        validate: @escaping (String) -> String? = { _ in nil },
        normalize: @escaping (String) -> String = { $0 }
    ) {
        self.title = title
        self.subtitle = subtitle
        _text = text
        self.prompt = prompt
        self.validate = validate
        self.normalize = normalize
        _draft = State(initialValue: SettingsTextDraft(text.wrappedValue))
    }

    var body: some View {
        TextField(text: $draft.text, prompt: prompt) {
            Text(title)
            if let error = validate(draft.text) {
                NoticeLabel(error, severity: .error)
            } else if let subtitle {
                Text(subtitle)
            }
        }
        .focused($isFocused)
        .onSubmit(commit)
        .onExitCommand { draft.revert() }
        .onChange(of: isFocused) { focused in
            if !focused { commit() }
        }
        .onChange(of: text) { newValue in
            draft.resync(to: newValue)
        }
        .onAppear {
            draft.resync(to: text)
        }
        .onDisappear(perform: commit)
    }

    private func resolve(_ candidate: String) -> SettingsDraftResolution<String> {
        validate(candidate) == nil ? .accept(normalize(candidate)) : .revert
    }

    private func commit() {
        if let committed = draft.commit(to: text, resolve: resolve) {
            text = committed
        }
        draft.settle(to: text)
    }
}
