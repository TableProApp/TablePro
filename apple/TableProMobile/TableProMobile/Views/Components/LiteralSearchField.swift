import SwiftUI
import UIKit

// A search the server runs with LIKE: SwiftUI's `.searchable` field cannot turn smart quotes off, and Smart Punctuation
// would send `O’Brien` for `O'Brien`.
struct LiteralSearchField: UIViewRepresentable {
    private let prompt: String
    @Binding private var text: String
    @Binding private var isEditing: Bool
    private let onSubmit: () -> Void

    init(_ prompt: LocalizedStringResource, text: Binding<String>, isEditing: Binding<Bool>, onSubmit: @escaping () -> Void) {
        self.prompt = String(localized: prompt)
        self._text = text
        self._isEditing = isEditing
        self.onSubmit = onSubmit
    }

    static func configure(_ bar: UISearchBar) {
        bar.searchBarStyle = .minimal
        bar.returnKeyType = .search
        bar.applyLiteralInputTraits()
    }

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        Self.configure(bar)
        bar.delegate = context.coordinator
        bar.placeholder = prompt
        bar.text = text
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        context.coordinator.field = self
        // Text being composed is the input method's until it is committed.
        if bar.searchTextField.markedTextRange == nil, bar.text != text {
            bar.text = text
        }
        if bar.placeholder != prompt {
            bar.placeholder = prompt
        }
        bar.isUserInteractionEnabled = context.environment.isEnabled
        // Focusing sends the delegate's begin-editing call, which writes `isEditing`; not while SwiftUI is updating.
        if isEditing, !bar.searchTextField.isFirstResponder {
            DispatchQueue.main.async { bar.searchTextField.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView bar: UISearchBar, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: bar.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(field: self)
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var field: LiteralSearchField

        init(field: LiteralSearchField) {
            self.field = field
        }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            field.text = searchText
        }

        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(true, animated: true)
            field.isEditing = true
        }

        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
            searchBar.setShowsCancelButton(false, animated: true)
            field.isEditing = false
        }

        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            field.onSubmit()
            searchBar.resignFirstResponder()
        }

        // As the system search does, Cancel clears the search and ends it.
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            searchBar.text = ""
            field.text = ""
            searchBar.resignFirstResponder()
        }
    }
}
