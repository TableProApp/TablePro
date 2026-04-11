//
//  SQLHighlightTextView.swift
//  TableProMobile
//

import SwiftUI
import UIKit

struct SQLHighlightTextView: UIViewRepresentable {
    @Binding var text: String

    private static let font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textStorage.delegate = context.coordinator
        textView.inputAccessoryView = context.coordinator.makeAccessoryToolbar()
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
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        var parent: SQLHighlightTextView
        var isUpdating = false
        weak var textView: UITextView?

        init(_ parent: SQLHighlightTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isUpdating else { return }
            parent.text = textView.text
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
            let toolbar = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
            toolbar.backgroundColor = .secondarySystemBackground

            let separator = UIView()
            separator.backgroundColor = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            toolbar.addSubview(separator)

            let scrollView = UIScrollView()
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false

            let stackView = UIStackView()
            stackView.axis = .horizontal
            stackView.spacing = 8
            stackView.translatesAutoresizingMaskIntoConstraints = false

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
                separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

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
            var config = UIButton.Configuration.gray()
            config.title = keyword
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var attrs = incoming
                attrs.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium)
                return attrs
            }
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            let button = UIButton(configuration: config)
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
    }
}
