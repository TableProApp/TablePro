import Combine
import Foundation

// A `@StateObject` so the model is built once per field: a `@State` seed reindents the value on every parent body.
@MainActor
internal final class JsonFieldEditor: ObservableObject {
    @Published private(set) var model: JsonFieldEditingModel
    // Moves each time the text is replaced from outside, which gives the editor a new history.
    @Published private(set) var replacements = 0
    private var openedDocument: UUID?

    internal init(storedValue: String, documentID: UUID?) {
        model = JsonFieldEditingModel(storedValue: storedValue)
        openedDocument = documentID
    }

    internal func typed(_ text: String) -> String? {
        model.typed(text)
    }

    internal func sync(documentID: UUID?, value: String) {
        if documentID != openedDocument {
            openedDocument = documentID
            model = JsonFieldEditingModel(storedValue: value)
            replacements &+= 1
        } else if model.received(value) {
            replacements &+= 1
        }
    }
}
