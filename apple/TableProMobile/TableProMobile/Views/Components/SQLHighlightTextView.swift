import SwiftUI
import UIKit

struct SQLHighlightTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let completion: QueryCompletionController?

    private static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    init(text: Binding<String>, isFocused: Binding<Bool> = .constant(false), completion: QueryCompletionController? = nil) {
        self._text = text
        self._isFocused = isFocused
        self.completion = completion
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = SQLEditorTextView()
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.inlinePredictionType = .no
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textStorage.delegate = context.coordinator
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
        context.coordinator.connectCompletion(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            context.coordinator.isUpdating = true
            textView.text = text
            let length = (text as NSString).length
            if length > 0 {
                SQLSyntaxHighlighter.highlight(textView.textStorage, in: NSRange(location: 0, length: length))
            }
            context.coordinator.isUpdating = false
            context.coordinator.requestSuggestions(for: textView)
        }
        if isFocused, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        var parent: SQLHighlightTextView
        var isUpdating = false
        weak var textView: UITextView?
        private weak var suggestionBar: QuerySuggestionBar?
        private weak var accessoryScrollView: UIScrollView?

        init(_ parent: SQLHighlightTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.text = textView.text
            requestSuggestions(for: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            requestSuggestions(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters), !isUpdating else { return }
            DispatchQueue.main.async {
                SQLSyntaxHighlighter.highlight(textStorage, in: editedRange)
            }
        }

        // MARK: - Keyboard Accessory Toolbar

        func makeAccessoryToolbar() -> UIView {
            let toolbar = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            toolbar.autoresizingMask = .flexibleWidth
            toolbar.backgroundColor = .secondarySystemBackground

            let separator = UIView()
            separator.backgroundColor = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(separator)

            let separatorHeight = separator.heightAnchor.constraint(
                equalToConstant: HairlineThickness.points(forDisplayScale: toolbar.traitCollection.displayScale)
            )
            toolbar.registerForTraitChanges([UITraitDisplayScale.self]) { (view: UIView, _) in
                separatorHeight.constant = HairlineThickness.points(forDisplayScale: view.traitCollection.displayScale)
            }

            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let stackView = UIStackView()
            stackView.axis = .horizontal
            stackView.spacing = 8
            stackView.translatesAutoresizingMaskIntoConstraints = false

            let suggestionBar = QuerySuggestionBar()
            suggestionBar.onSelect = { [weak self] suggestion in self?.accept(suggestion) }
            stackView.addArrangedSubview(suggestionBar)
            self.suggestionBar = suggestionBar
            accessoryScrollView = scrollView

            let keywords = ["SELECT", "FROM", "WHERE", "JOIN", "AND", "OR", "INSERT", "UPDATE", "DELETE", "*", "(", ")", ";"]
            for keyword in keywords {
                stackView.addArrangedSubview(makeKeywordButton(keyword))
            }

            scrollView.addSubview(stackView)

            let doneButton = UIButton(type: .system)
            doneButton.setTitle(String(localized: "Done"), for: .normal)
            doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
            doneButton.addTarget(self, action: #selector(dismissKeyboard), for: .touchUpInside)
            doneButton.translatesAutoresizingMaskIntoConstraints = false
            doneButton.setContentHuggingPriority(.required, for: .horizontal)
            doneButton.setContentCompressionResistancePriority(.required, for: .horizontal)

            toolbar.addSubview(scrollView)
            toolbar.addSubview(doneButton)

            NSLayoutConstraint.activate([
                separator.topAnchor.constraint(equalTo: toolbar.topAnchor),
                separator.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
                separatorHeight,

                scrollView.topAnchor.constraint(equalTo: toolbar.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
                scrollView.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
                scrollView.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor, constant: -8),

                stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
                stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
                stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

                doneButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
                doneButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
            ])

            return toolbar
        }

        private func makeKeywordButton(_ keyword: String) -> UIButton {
            let button = UIButton(configuration: QuerySuggestionBar.keyConfiguration(title: keyword))
            button.addTarget(self, action: #selector(keywordTapped(_:)), for: .touchUpInside)
            return button
        }

        @objc private func keywordTapped(_ sender: UIButton) {
            guard let keyword = sender.configuration?.title else { return }
            let needsSpace = keyword.count > 1
            textView?.insertText(needsSpace ? keyword + " " : keyword)
        }

        @objc private func dismissKeyboard() {
            textView?.resignFirstResponder()
        }

        func connectCompletion(to textView: SQLEditorTextView) {
            guard let completion = parent.completion else { return }
            completion.onSuggestionsChange = { [weak self] suggestions in self?.showSuggestions(suggestions) }
            textView.onAcceptSuggestion = { [weak self] in
                guard let first = self?.parent.completion?.suggestions.first else { return }
                self?.accept(first)
            }
            textView.onHideSuggestions = { [weak self] in
                guard let completion = self?.parent.completion else { return }
                completion.hide()
                self?.showSuggestions(completion.suggestions)
            }
        }

        func requestSuggestions(for textView: UITextView) {
            parent.completion?.request(
                text: textView.text,
                selection: textView.selectedRange,
                hasMarkedText: textView.markedTextRange != nil
            )
        }

        func accept(_ suggestion: QuerySuggestion) {
            guard let completion = parent.completion, let textView, textView.markedTextRange == nil,
                  let edit = completion.edit(for: suggestion, in: textView.text, selection: textView.selectedRange)
            else { return }
            apply(edit, to: textView)
            showSuggestions(completion.suggestions)
        }

        // If replace(_:withText:) skips textViewDidChange, the next updateUIView would put the old text back.
        func apply(_ edit: QueryCompletionEdit, to textView: UITextView) {
            guard let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                  let end = textView.position(from: start, offset: edit.range.length),
                  let range = textView.textRange(from: start, to: end) else { return }
            textView.replace(range, withText: edit.text)
            textView.selectedRange = NSRange(location: edit.caret, length: 0)
            if parent.text != textView.text {
                parent.text = textView.text
            }
        }

        private func showSuggestions(_ suggestions: [QuerySuggestion]) {
            (textView as? SQLEditorTextView)?.showsSuggestions = !suggestions.isEmpty
            guard let suggestionBar, suggestionBar.suggestions != suggestions else { return }
            suggestionBar.show(suggestions)
            scrollAccessoryToLeadingEdge()
        }

        // scrollRectToVisible would line up the trailing edge of a bar wider than the scroll view, which is zero wide
        // while the keyboard is off screen.
        private func scrollAccessoryToLeadingEdge() {
            guard let scrollView = accessoryScrollView else { return }
            scrollView.contentOffset.x = -scrollView.adjustedContentInset.left
        }
    }
}
