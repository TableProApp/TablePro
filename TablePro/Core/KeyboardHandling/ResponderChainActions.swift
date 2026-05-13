//
//  ResponderChainActions.swift
//  TablePro
//
//  Documentation protocol listing all responder chain actions used in TablePro.
//  This is a reference guide, not implemented by any class directly.
//
//  ## Architecture Pattern
//
//  TablePro uses three mechanisms for keyboard shortcuts and commands:
//
//  1. **Responder Chain** (Apple Standard):
//     - Standard edit actions: copy, paste, undo, delete, cancelOperation (ESC)
//     - Context-aware: First responder handles action appropriately
//     - Commands send via `NSApp.sendAction(#selector(...), to: nil, from: nil)`
//
//  2. **@FocusedValue** (Menu/Toolbar → single handler):
//     - Most menu commands call `MainContentCommandActions` directly
//     - Toolbar buttons also use `@FocusedValue` for direct calls
//     - Clean method calls, no global event bus
//     - Commands are automatically nil (disabled) when no connection is active
//
//  3. **AppCommands** (Multi-listener broadcasts only):
//     - `refreshData` (Sidebar + Coordinator + StructureView)
//     - Non-menu commands from AppKit views (DataGrid, SidebarView context menus)
//     - Typed Combine publishers for broadcasts where multiple views respond
//
//  ## Example Flow
//
//  ```
//  User presses: Cmd+Delete
//    ↓
//  SwiftUI Command: .keyboardShortcut(.delete, modifiers: .command)
//    ↓
//  TableProApp: NSApp.sendAction(#selector(delete(_:)), to: nil, from: nil)
//    ↓
//  Responder Chain: First Responder (KeyHandlingTableView)
//    ↓
//  KeyHandlingTableView: @objc func delete(_ sender: Any?) { ... }
//  ```
//
//  ## Reference Files
//  - `TableProApp.swift` - SwiftUI Commands that define shortcuts
//  - `KeyHandlingTableView.swift` - Data grid keyboard handling
//  - `HistoryPanelView.swift` - SwiftUI history panel (uses onDeleteCommand)
//  - `EditorTextView.swift` - SQL editor keyboard handling
//

import AppKit

/// Documentation protocol listing all responder chain actions in TablePro.
///
/// **IMPORTANT**: This protocol is for documentation only. Do NOT implement it
/// on any classes. Instead, add individual `@objc` methods as needed.
///
/// Responders should implement:
/// 1. The `@objc` action method (e.g., `@objc func delete(_ sender: Any?)`)
/// 2. Validation via `NSUserInterfaceValidations` or `NSMenuItemValidation`
///
@objc protocol TableProResponderActions {
    // MARK: - Standard Edit Menu Actions

    /// Delete the selected items
    /// - Standard AppKit selector for Delete/Backspace key
    /// - Triggered by: Delete key, Cmd+Delete, or Edit > Delete menu
    @objc optional func delete(_ sender: Any?)

    /// Copy selected content to clipboard
    /// - Standard AppKit selector for Cmd+C
    @objc optional func copy(_ sender: Any?)

    /// Paste clipboard content
    /// - Standard AppKit selector for Cmd+V
    @objc optional func paste(_ sender: Any?)

    /// Cut selected content to clipboard
    /// - Standard AppKit selector for Cmd+X
    @objc optional func cut(_ sender: Any?)

    /// Select all items
    /// - Standard AppKit selector for Cmd+A
    @objc optional func selectAll(_ sender: Any?)

    /// Undo last action
    /// - Standard AppKit selector for Cmd+Z
    @objc optional func undo(_ sender: Any?)

    /// Redo last undone action
    /// - Standard AppKit selector for Cmd+Shift+Z
    @objc optional func redo(_ sender: Any?)

    // MARK: - Standard Navigation Actions

    /// Move selection up
    /// - Standard AppKit selector for Up Arrow
    @objc optional func moveUp(_ sender: Any?)

    /// Move selection down
    /// - Standard AppKit selector for Down Arrow
    @objc optional func moveDown(_ sender: Any?)

    /// Move selection left
    /// - Standard AppKit selector for Left Arrow
    @objc optional func moveLeft(_ sender: Any?)

    /// Move selection right
    /// - Standard AppKit selector for Right Arrow
    @objc optional func moveRight(_ sender: Any?)

    /// Insert newline (Enter/Return key)
    /// - Standard AppKit selector for Return key
    @objc optional func insertNewline(_ sender: Any?)

    /// Cancel current operation (ESC key)
    /// - Standard AppKit selector for Escape key
    /// - Automatically called by `.onExitCommand` in SwiftUI
    @objc optional func cancelOperation(_ sender: Any?)

    // MARK: - App-Specific Database Actions

    /// Add a new row to the current table
    /// - Custom action for Cmd+N in data grid
    @objc optional func addRow(_ sender: Any?)

    /// Duplicate the selected row
    /// - Custom action for Cmd+D
    @objc optional func duplicateRow(_ sender: Any?)

    /// Save pending changes to database
    /// - Custom action for Cmd+S
    @objc optional func saveChanges(_ sender: Any?)

    /// Refresh data from database
    /// - Custom action for Cmd+R
    @objc optional func refreshData(_ sender: Any?)

    /// Execute SQL query
    /// - Custom action for Cmd+Enter in editor
    @objc optional func executeQuery(_ sender: Any?)

    /// Clear current selection
    /// - Custom action for Cmd+Esc
    @objc optional func clearSelection(_ sender: Any?)

    // MARK: - View Actions

    /// Toggle table browser visibility
    /// - Custom action for Cmd+B
    @objc optional func toggleTableBrowser(_ sender: Any?)

    /// Toggle inspector panel
    /// - Custom action for Cmd+I
    @objc optional func toggleInspector(_ sender: Any?)

    /// Toggle filters panel
    /// - Custom action for Cmd+F
    @objc optional func toggleFilters(_ sender: Any?)

    /// Toggle query history panel
    /// - Custom action for Cmd+H
    @objc optional func toggleHistory(_ sender: Any?)
}

// MARK: - Implementation Guide

/*

 ## How to Implement Responder Chain Actions

 ### Step 1: Add @objc Method to Your Responder

 ```swift
 final class MyTableView: NSTableView {
 override var acceptsFirstResponder: Bool { true }

 @objc func delete(_ sender: Any?) {
 // Your delete logic here
 logger.debug("Deleting selected rows")
 }
 }
 ```

 ### Step 2: Add Validation (Optional but Recommended)

 ```swift
 extension MyTableView: NSUserInterfaceValidations {
 func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
 switch item.action {
 case #selector(delete(_:)):
 // Enable Delete only when rows are selected
 return !selectedRowIndexes.isEmpty
 default:
 return false
 }
 }
 }
 ```

 ### Step 3: Register Command in TableProApp.swift

 ```swift
 .commands {
 CommandGroup(after: .newItem) {
 Button("Delete Row") {
 NSApp.sendAction(#selector(TableProResponderActions.delete(_:)),
 to: nil, from: nil)
 }
 .keyboardShortcut(.delete, modifiers: .command)
 }
 }
 ```

 ### Step 4: Use interpretKeyEvents for Bare Keys (Optional)

 For non-modifier keys (arrows, Return, ESC), use `interpretKeyEvents`:

 ```swift
 override func keyDown(with event: NSEvent) {
 interpretKeyEvents([event])
 }

 @objc override func moveUp(_ sender: Any?) {
 // Custom up arrow handling
 }
 ```

 ## Benefits of Responder Chain

 ✅ **Automatic validation** - Menu items enable/disable based on context
 ✅ **No manual routing** - macOS finds the right handler automatically
 ✅ **Standard behavior** - Users expect Cmd+C/V/Z to work everywhere
 ✅ **VoiceOver support** - Accessibility built-in
 ✅ **Easy to extend** - Just add @objc methods, no global event bus

 ## Anti-Patterns to Avoid

 ❌ **NotificationCenter for commands** - Bypasses validation, hard to debug
 ❌ **Magic keyCode numbers** - Use KeyCode enum instead
 ❌ **performKeyEquivalent for bare keys** - Only for Cmd+ shortcuts
 ❌ **Custom ESC systems** - Use cancelOperation(_:) selector
 ❌ **Manual keyDown switches** - Use interpretKeyEvents + selectors

 */
