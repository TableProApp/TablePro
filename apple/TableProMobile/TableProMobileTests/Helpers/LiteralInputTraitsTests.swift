@testable import TableProMobile
import Testing
import UIKit

@MainActor
struct LiteralInputTraitsTests {
    @Test("A literal text field turns off every automatic text change")
    func textFieldTraits() {
        let field = UITextField()
        #expect(field.smartQuotesType == .default)

        field.applyLiteralInputTraits()

        #expect(field.autocorrectionType == .no)
        #expect(field.autocapitalizationType == UITextAutocapitalizationType.none)
        #expect(field.spellCheckingType == .no)
        #expect(field.smartQuotesType == .no)
        #expect(field.smartDashesType == .no)
        #expect(field.smartInsertDeleteType == .no)
        #expect(field.inlinePredictionType == .no)
        #expect(field.mathExpressionCompletionType == .no)
        #expect(field.writingToolsBehavior == UIWritingToolsBehavior.none)
    }

    @Test("A literal text view turns off every automatic text change")
    func textViewTraits() {
        let textView = UITextView()
        #expect(textView.smartQuotesType == .default)

        textView.applyLiteralInputTraits()

        #expect(textView.autocorrectionType == .no)
        #expect(textView.autocapitalizationType == UITextAutocapitalizationType.none)
        #expect(textView.spellCheckingType == .no)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.smartInsertDeleteType == .no)
        #expect(textView.inlinePredictionType == .no)
        #expect(textView.mathExpressionCompletionType == .no)
        #expect(textView.writingToolsBehavior == UIWritingToolsBehavior.none)
    }

    @Test("The traits leave the keyboard type the field asked for")
    func keyboardTypeKept() {
        let field = UITextField()
        field.keyboardType = .decimalPad
        field.applyLiteralInputTraits()
        #expect(field.keyboardType == .decimalPad)

        let textView = UITextView()
        textView.keyboardType = .numbersAndPunctuation
        textView.applyLiteralInputTraits()
        #expect(textView.keyboardType == .numbersAndPunctuation)
    }
}
