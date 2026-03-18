# Source Editor View

## Usage

CodeEditSourceEditor provides two APIs for creating an editor: SwiftUI and AppKit. We provide a fast and efficient SwiftUI API that avoids unnecessary view updates whenever possible. It also provides extremely customizable and flexible configuration options, including two-way bindings for state like cursor positions and scroll position. 

For more complex features that require access to the underlying text view or text storage, we've developed the <doc:TextViewCoordinators> API. Using this API, developers can inject custom behavior into the editor as events happen, without having to work with state or bindings.

#### SwiftUI

```swift
import CodeEditSourceEditor

struct ContentView: View {

    @State var text = "let x = 1.0"
    // For large documents use a text storage object (avoids SwiftUI comparisons)
    // var text: NSTextStorage
    
    /// Automatically updates with cursor positions, scroll position, find panel text.
    /// Everything in this object is two-way, use it to update cursor positions, scroll position, etc.
    @State var editorState = SourceEditorState()
    
    /// Configure the editor's appearance, features, and editing behavior...
    @State var theme = EditorTheme(...)
    @State var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    @State var indentOption = .spaces(count: 4)
    @State var editorOverscroll = 0.3
    @State var showMinimap = true

    /// *Powerful* customization options with text coordinators 
    @State var autoCompleteCoordinator = AutoCompleteCoordinator()

    var body: some View { 
        SourceEditor(
            $text,
            language: language,
            configuration: SourceEditorConfiguration(
                appearance: .init(theme: theme, font: font),
                behavior: .init(indentOption: indentOption),
                layout: .init(editorOverscroll: editorOverscroll),
                peripherals: .init(showMinimap: showMinimap)
            ),
            state: $editorState,
            coordinators: [autoCompleteCoordinator]
        )
    }

    /// Autocompletes "Hello" to "Hello world!" whenever it's typed.
    class AutoCompleteCoordinator: TextViewCoordinator {
        func prepareCoordinator(controller: TextViewController) { }

        func textViewDidChangeText(controller: TextViewController) {
            for cursorPosition in controller.cursorPositions.reversed() where cursorPosition.range.location >= 5 {
                let location = cursorPosition.range.location
                let previousRange = NSRange(start: location - 5, end: location)
                let string = (controller.text as NSString).substring(with: previousRange)

                if string.lowercased() == "hello" {
                    controller.textView.replaceCharacters(in: NSRange(location: location, length: 0), with: " world!")
                }
            }
        }
    }
}
```

#### AppKit

```swift
var theme = EditorTheme(...)
var font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
var indentOption = .spaces(count: 4)
var editorOverscroll = 0.3
var showMinimap = true

let editorController = TextViewController(
    string: "let x = 10;",
    language: .swift,
    config: SourceEditorConfiguration(
        appearance: .init(theme: theme, font: font),
        behavior: .init(indentOption: indentOption),
        layout: .init(editorOverscroll: editorOverscroll),
        peripherals: .init(showMinimap: showMinimap)
    ),
    cursorPositions: [CursorPosition(line: 0, column: 0)],
    highlightProviders: [], // Use the tree-sitter syntax highlighting provider by default
    undoManager: nil,
    coordinators: [], // Optionally inject editing behavior or other plugins.
    completionDelegate: nil, // Provide code suggestions while typing via a delegate object.
    jumpToDefinitionDelegate // Allow users to perform the 'jump to definition' using a delegate object.
)
```

To add the controller to your view, add it as a child view controller and add the editor's view to your view hierarchy.

```swift
final class MyController: NSViewController {
    override func loadView() {
        super.loadView()
        let editorController: TextViewController = /**/

        addChild(editorController)
        view.addSubview(editorController.view)
        editorController.view.viewDidMoveToSuperview()
    }
}
```

For more AppKit API options, see the documentation on ``TextViewController``.

## Topics

- ``SourceEditor``
