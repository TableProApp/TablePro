import UIKit

final class SQLEditorTextView: UITextView {
    var showsSuggestions = false
    var onAcceptSuggestion: (() -> Void)?
    var onHideSuggestions: (() -> Void)?

    // Return, the arrows and Control keep their editing meaning (HIG Keyboards); Full Keyboard Access reaches the other chips.
    private lazy var suggestionCommands: [UIKeyCommand] = {
        let accept = UIKeyCommand(
            title: String(localized: "Accept Suggestion"),
            action: #selector(acceptSuggestion(_:)),
            input: "\t"
        )
        let hide = UIKeyCommand(
            title: String(localized: "Hide Suggestions"),
            action: #selector(hideSuggestions(_:)),
            input: UIKeyCommand.inputEscape
        )
        // Without priority the text system takes the key first and Tab types a tab character.
        for command in [accept, hide] {
            command.wantsPriorityOverSystemBehavior = true
        }
        return [accept, hide]
    }()

    override var keyCommands: [UIKeyCommand]? {
        guard showsSuggestions else { return super.keyCommands }
        return (super.keyCommands ?? []) + suggestionCommands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(acceptSuggestion(_:)) || action == #selector(hideSuggestions(_:)) {
            return showsSuggestions
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func acceptSuggestion(_ sender: UIKeyCommand) {
        onAcceptSuggestion?()
    }

    @objc private func hideSuggestions(_ sender: UIKeyCommand) {
        onHideSuggestions?()
    }
}
