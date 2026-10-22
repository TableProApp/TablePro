import SwiftUI
import UIKit

struct LiteralTextField: UIViewRepresentable {
    private let placeholder: String
    @Binding private var text: String
    private let keyboardType: UIKeyboardType

    init(_ titleKey: LocalizedStringResource, text: Binding<String>, keyboardType: UIKeyboardType = .default) {
        self.init(placeholder: String(localized: titleKey), text: text, keyboardType: keyboardType)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(_ title: Title, text: Binding<String>, keyboardType: UIKeyboardType = .default) {
        self.init(placeholder: String(title), text: text, keyboardType: keyboardType)
    }

    private init(placeholder: String, text: Binding<String>, keyboardType: UIKeyboardType) {
        self.placeholder = placeholder
        self._text = text
        self.keyboardType = keyboardType
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.applyLiteralInputTraits()
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.text = $text
        if field.text != text {
            field.text = text
        }
        if field.placeholder != placeholder {
            field.placeholder = placeholder
        }
        if field.keyboardType != keyboardType {
            field.keyboardType = keyboardType
            if field.isFirstResponder {
                field.reloadInputViews()
            }
        }
        field.isEnabled = context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView field: UITextField, context: Context) -> CGSize? {
        let fitting = field.intrinsicContentSize
        guard let width = proposal.width, width.isFinite else { return fitting }
        return CGSize(width: width, height: fitting.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }

        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
    }
}
