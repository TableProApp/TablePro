//
//  TextViewCoordinator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 11/14/23.
//

import AppKit

/// A protocol that can be used to receive extra state change messages from <doc:SourceEditorView>.
///
/// These are used as a way to push messages up from underlying components into SwiftUI land without requiring passing
/// callbacks for each message to the
/// ``SourceEditor/init(_:language:configuration:state:highlightProviders:undoManager:coordinators:)`` initializer.
///
/// They're very useful for updating UI that is directly related to the state of the editor, such as the current
/// cursor position. For an example, see the ``CombineCoordinator`` class, which implements combine publishers for the
/// messages this protocol provides.
///
/// Conforming objects can also be used to get more detailed text editing notifications by conforming to the
/// `TextViewDelegate` (from CodeEditTextView) protocol. In that case they'll receive most text change notifications.
public protocol TextViewCoordinator: AnyObject {
    /// Called when an instance of ``TextViewController`` is available. Use this method to install any delegates,
    /// perform any modifications on the text view or controller, or capture the text view for later use in your app.
    ///
    /// - Parameter controller: The text controller. This is safe to keep a weak reference to, as long as it is
    ///                         dereferenced when ``TextViewCoordinator/destroy()-9nzfl`` is called.
    func prepareCoordinator(controller: TextViewController)

    /// Called when the controller's `viewDidAppear` method is called by AppKit.
    /// - Parameter controller: The text view controller that did appear.
    func controllerDidAppear(controller: TextViewController)

    /// Called when the controller's `viewDidDisappear` method is called by AppKit.
    /// - Parameter controller: The text view controller that did disappear.
    func controllerDidDisappear(controller: TextViewController)

    /// Called when the text view's text changed.
    /// - Parameter controller: The text controller.
    func textViewDidChangeText(controller: TextViewController)

    /// Called after the text view updated it's cursor positions.
    /// - Parameter newPositions: The new positions of the cursors.
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition])

    /// Called when the pointer comes to rest on a collapsed fold's placeholder, and again when it leaves one.
    ///
    /// The editor resolves this itself because it is the only thing that knows where a placeholder is drawn: a
    /// placeholder is painted by the layout manager rather than being a view, so there is nothing for an app to
    /// attach its own tracking to. What to show for the fold, and after how long, is left to the receiver.
    /// - Parameters:
    ///   - controller: The text controller.
    ///   - hit: The collapsed fold under the pointer, or `nil` when the pointer is on none.
    func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?)

    /// Called when the text controller is being destroyed. Use to free any necessary resources.
    func destroy()
}

/// Default implementations
public extension TextViewCoordinator {
    func controllerDidAppear(controller: TextViewController) { }
    func controllerDidDisappear(controller: TextViewController) { }
    func textViewDidChangeText(controller: TextViewController) { }
    func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) { }
    func textViewDidChangeHoveredFold(controller: TextViewController, hit: CollapsedFoldHit?) { }
    func destroy() { }
}
