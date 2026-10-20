import SwiftUI
import UIKit

struct JSONTextView: UIViewRepresentable {
    struct CaretRequest: Equatable {
        let utf16Offset: Int
        let serial: Int
    }

    @Binding private var text: String
    private let isEditable: Bool
    private let caretRequest: CaretRequest?

    init(text: Binding<String>, caretRequest: CaretRequest? = nil) {
        self._text = text
        self.isEditable = true
        self.caretRequest = caretRequest
    }

    init(readOnlyText: String) {
        self._text = .constant(readOnlyText)
        self.isEditable = false
        self.caretRequest = nil
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.applyLiteralInputTraits()
        textView.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 17, weight: .regular))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.isFindInteractionEnabled = true
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.text = text
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        if textView.text != text {
            textView.text = text
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if let caretRequest, caretRequest != context.coordinator.appliedCaretRequest {
            context.coordinator.appliedCaretRequest = caretRequest
            placeCaret(at: caretRequest.utf16Offset, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private func placeCaret(at utf16Offset: Int, in textView: UITextView) {
        let location = min(max(utf16Offset, 0), textView.textStorage.length)
        if textView.isEditable, !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        textView.selectedRange = NSRange(location: location, length: 0)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var appliedCaretRequest: CaretRequest?

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
