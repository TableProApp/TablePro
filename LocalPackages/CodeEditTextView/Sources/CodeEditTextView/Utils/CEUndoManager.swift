//
//  CEUndoManager.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 7/8/23.
//

import AppKit
import TextStory

/// Maintains a history of edits applied to the editor and allows for undo/redo actions using those edits.
/// 
/// This object also groups edits into sequences that make for a better undo/redo editing experience such as:
/// - Breaking undo groups on newlines
/// - Grouping pasted text
///
/// If needed, the automatic undo grouping can be overridden using the `beginGrouping()` and `endGrouping()` methods.
public class CEUndoManager: UndoManager {
    /// Represents a group of mutations that should be treated as one mutation when undoing/redoing.
    private struct UndoGroup {
        var mutations: [Mutation]
    }

    /// A single undo mutation.
    private struct Mutation {
        var mutation: TextMutation
        var inverse: TextMutation
    }

    private var _isUndoing: Bool = false
    private var _isRedoing: Bool = false

    override public var isUndoing: Bool { _isUndoing }
    override public var isRedoing: Bool { _isRedoing }

    override public var undoCount: Int { undoStack.count }
    override public var redoCount: Int { redoStack.count }

    override public var canUndo: Bool { !undoStack.isEmpty }
    override public var canRedo: Bool { !redoStack.isEmpty }

    /// A stack of operations that can be undone.
    private var undoStack: [UndoGroup] = []
    /// A stack of operations that can be redone.
    private var redoStack: [UndoGroup] = []

    private weak var textView: TextView?
    private(set) public var isGrouping: Bool = false

    /// After ``endUndoGrouping`` is called, we'd expect the next mutation to be exclusive no matter what. This
    /// flag facilitates that, and is set by ``endUndoGrouping``
    private var shouldBreakNextGroup: Bool = false

    /// True when the manager is ignoring mutations.
    private var isDisabled: Bool = false

    // MARK: - Init

    override public init() { }

    convenience init(textView: TextView) {
        self.init()
        self.textView = textView
    }

    // MARK: - Undo/Redo

    /// Performs an undo operation if there is one available.
    override public func undo() {
        guard !isDisabled, let textView else {
            return
        }

        guard let item = undoStack.popLast() else {
            NSSound.beep()
            return
        }

        _isUndoing = true
        NotificationCenter.default.post(name: .NSUndoManagerWillUndoChange, object: self)
        textView.textStorage.beginEditing()
        for mutation in item.mutations.reversed() {
            textView.replaceCharacters(
                in: mutation.inverse.range,
                with: mutation.inverse.string,
                skipUpdateSelection: true
            )
        }
        textView.textStorage.endEditing()

        updateSelectionsForMutations(mutations: item.mutations.map { $0.mutation })
        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidUndoChange, object: self)
        redoStack.append(item)
        _isUndoing = false
    }

    /// Performs a redo operation if there is one available.
    override public func redo() {
        guard !isDisabled, let textView else {
            return
        }

        guard let item = redoStack.popLast() else {
            NSSound.beep()
            return
        }

        _isRedoing = true
        NotificationCenter.default.post(name: .NSUndoManagerWillRedoChange, object: self)
        textView.selectionManager.removeCursors()
        textView.textStorage.beginEditing()
        for mutation in item.mutations {
            textView.replaceCharacters(
                in: mutation.mutation.range,
                with: mutation.mutation.string,
                skipUpdateSelection: true
            )
        }
        textView.textStorage.endEditing()

        updateSelectionsForMutations(mutations: item.mutations.map { $0.inverse })
        textView.scrollSelectionToVisible()

        NotificationCenter.default.post(name: .NSUndoManagerDidRedoChange, object: self)
        undoStack.append(item)
        _isRedoing = false
    }

    /// We often undo/redo a group of mutations that contain updated ranges that are next to each other but for a user
    /// should be one continuous range. This merges those ranges into a set of disjoint ranges before updating the
    /// selection manager.
    private func updateSelectionsForMutations(mutations: [TextMutation]) {
        if mutations.reduce(0, { $0 + $1.range.length }) == 0 {
            if let minimumMutation = mutations.min(by: { $0.range.location < $1.range.location }) {
                // If the mutations are only deleting text (no replacement), we just place the cursor at the last range,
                // since all the ranges are the same but the other method will return no ranges (empty range).
                textView?.selectionManager.setSelectedRange(
                    NSRange(location: minimumMutation.range.location, length: 0)
                )
            }
        } else {
            let mergedRanges = mutations.reduce(into: IndexSet(), { set, mutation in
                set.insert(range: mutation.range)
            })
            textView?.selectionManager.setSelectedRanges(mergedRanges.rangeView.map { NSRange($0) })
        }
    }

    /// Clears the undo/redo stacks.
    public func clearStack() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Mutations

    public override func registerUndo(withTarget target: Any, selector: Selector, object anObject: Any?) {
        // no-op, but just in case to save resources:
        removeAllActions()
    }

    /// Registers a mutation into the undo stack.
    ///
    /// Calling this method while the manager is in an undo/redo operation will result in a no-op.
    /// - Parameter mutation: The mutation to register for undo/redo
    public func registerMutation(_ mutation: TextMutation) {
        removeAllActions()
        guard let textView,
              let textStorage = textView.textStorage,
              !isUndoing,
              !isRedoing else {
            return
        }
        let newMutation = Mutation(mutation: mutation, inverse: textStorage.inverseMutation(for: mutation))
        // We can continue a group if:
        // - A group exists
        // - We're not direct to break the current group
        // - We're forced grouping OR we automagically detect we can group.
        if !undoStack.isEmpty,
            let lastMutation = undoStack.last?.mutations.last,
           !shouldBreakNextGroup,
           isGrouping || shouldContinueGroup(newMutation, lastMutation: lastMutation) {
            undoStack[undoStack.count - 1].mutations.append(newMutation)
        } else {
            undoStack.append(UndoGroup(mutations: [newMutation]))
            shouldBreakNextGroup = false
        }
        redoStack.removeAll()
    }

    // MARK: - Grouping

    /// Groups all incoming mutations.
    override public func beginUndoGrouping() {
        guard !isGrouping else { return }
        isGrouping = true
        // This is a new undo group, break for it.
        shouldBreakNextGroup = true
    }

    /// Stops grouping all incoming mutations.
    override public func endUndoGrouping() {
        guard isGrouping else { return }
        isGrouping = false
        // We just ended a group, do not allow the next mutation to be added to the group we just made.
        shouldBreakNextGroup = true
    }

    /// Determines whether or not two mutations should be grouped.
    ///
    /// Will break group if:
    /// - Last mutation is delete and new is insert, and vice versa *(insert and delete)*.
    /// - Last mutation was not whitespace, new is whitespace *(insert)*.
    /// - New mutation is a newline *(insert and delete)*.
    /// - New mutation is not sequential with the last one *(insert and delete)*.
    ///
    /// - Parameters:
    ///   - mutation: The current mutation.
    ///   - lastMutation: The last mutation applied to the document.
    /// - Returns: Whether or not the given mutations can be grouped.
    private func shouldContinueGroup(_ mutation: Mutation, lastMutation: Mutation) -> Bool {
        // If last mutation was delete & new is insert or vice versa, split group
        if (mutation.mutation.range.length > 0 && lastMutation.mutation.range.length == 0)
            || (mutation.mutation.range.length == 0 && lastMutation.mutation.range.length > 0) {
            return false
        }

        if mutation.mutation.string.isEmpty {
            // Deleting
            return (
                lastMutation.mutation.range.location == mutation.mutation.range.max
                && LineEnding(line: lastMutation.inverse.string) == nil
            )
        } else {
            // Inserting

            // Only attempt this check if the mutations are small enough.
            // If the last mutation was not whitespace, and the new one is, break the group.
            if lastMutation.mutation.string.count < 1024
                && mutation.mutation.string.count < 1024
                && !lastMutation.mutation.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && mutation.mutation.string.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }

            return (
                lastMutation.mutation.range.max + 1 == mutation.mutation.range.location
                && LineEnding(line: mutation.mutation.string) == nil
            )
        }
    }

    // MARK: - Disable

    /// Sets the undo manager to ignore incoming mutations until the matching `enable` method is called.
    /// Cannot be nested.
    public func disable() {
        isDisabled = true
    }

    /// Sets the undo manager to begin receiving incoming mutations after a call to `disable`
    /// Cannot be nested.
    public func enable() {
        isDisabled = false
    }

    // MARK: - Internal

    /// Sets a new text view to use for mutation registration, undo/redo operations.
    /// - Parameter newTextView: The new text view.
    func setTextView(_ newTextView: TextView) {
        self.textView = newTextView
    }
}
