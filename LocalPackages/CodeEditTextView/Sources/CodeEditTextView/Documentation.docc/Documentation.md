# ``CodeEditTextView``

A text editor designed to edit code documents.

## Overview

A text editor specialized for displaying and editing code documents. Features include basic text editing, extremely fast initial layout, support for handling large documents, customization options for code documents.

> This package contains a text view suitable for replacing `NSTextView` in some, ***specific*** cases. If you want a text view that can handle things like: left-to-right layout, custom layout elements, or feature parity with the system text view, consider using [STTextView](https://github.com/krzyzanowskim/STTextView) or [NSTextView](https://developer.apple.com/documentation/appkit/nstextview). The ``TextView`` exported by this library is designed to lay out documents made up of lines of text. However, it does not attempt to reason about the contents of the document. If you're looking to edit *source code* (indentation, syntax highlighting) consider using the parent library [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor).

The ``TextView`` class is an `NSView` subclass that can be embedded in a scroll view or used standalone. It parses and renders lines of a document and handles mouse and keyboard events for text editing. It also renders styled strings for use cases like syntax highlighting.

## Topics

### Text View

- ``TextView``
- ``CEUndoManager``

### Text Layout

- ``TextLayoutManager``
- ``TextLine``
- ``LineFragment``

### Text Selection

- ``TextSelectionManager``
- ``TextSelectionManager/TextSelection``
- ``CursorView``

### Supporting Types

- ``TextLineStorage``
- ``HorizontalEdgeInsets``
- ``LineEnding``
- ``LineBreakStrategy``
