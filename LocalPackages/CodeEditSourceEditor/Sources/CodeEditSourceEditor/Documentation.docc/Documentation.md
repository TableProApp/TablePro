# ``CodeEditSourceEditor``

A code editor with syntax highlighting powered by tree-sitter. 

## Overview

![logo](codeeditsourceeditor-logo)

An Xcode-inspired code editor view written in Swift powered by tree-sitter for [CodeEdit](https://github.com/CodeEditApp/CodeEdit). Features include syntax highlighting (based on the provided theme), code completion, find and replace, text diff, validation, current line highlighting, minimap, inline messages (warnings and errors), bracket matching, and more.

![banner](preview)

This package includes both `AppKit` and `SwiftUI` components. It also relies on the [`CodeEditLanguages`](https://github.com/CodeEditApp/CodeEditLanguages) for optional syntax highlighting using tree-sitter. 

> **CodeEditSourceEditor is currently in development and it is not ready for production use.** <br> Please check back later for updates on this project. Contributors are welcome as we build out the features mentioned above!

## Currently Supported Languages

See this issue [CodeEditLanguages#10](https://github.com/CodeEditApp/CodeEditLanguages/issues/10) on `CodeEditLanguages` for more information on supported languages.

## Dependencies

Special thanks to [Matt Massicotte](https://bsky.app/profile/massicotte.org) for the great work he's done!

| Package | Source | Author |
| :- | :- | :- |
| `SwiftTreeSitter` | [GitHub](https://github.com/ChimeHQ/SwiftTreeSitter) | [Matt Massicotte](https://bsky.app/profile/massicotte.org) |

## License

Licensed under the [MIT license](https://github.com/CodeEditApp/CodeEdit/blob/main/LICENSE.md).

## Topics

### Text View

- <doc:SourceEditorView> 
- ``SourceEditor``
- ``SourceEditorConfiguration``
- ``SourceEditorState``
- ``TextViewController``
- ``GutterView``

### Themes

- ``EditorTheme``

### Text Coordinators

- <doc:TextViewCoordinators>
- ``TextViewCoordinator``
- ``CombineCoordinator`` 

### Cursors

- ``CursorPosition``
