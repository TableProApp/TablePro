import UIKit

// SwiftUI cannot turn smart quotes off, and one curly quote breaks a JSON value or a filter.
extension UITextField {
    func applyLiteralInputTraits() {
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
    }
}

extension UITextView {
    func applyLiteralInputTraits() {
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
    }
}

// The bar keeps traits of its own beside its field's, so both are set.
extension UISearchBar {
    func applyLiteralInputTraits() {
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        searchTextField.applyLiteralInputTraits()
    }
}
