//
//  CombineCoordinator.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 5/19/24.
//

import Foundation
import Combine
import CodeEditTextView

/// A ``TextViewCoordinator`` class that publishes text changes and selection changes using Combine publishers.
///
/// This class provides two publisher streams: ``textUpdatePublisher`` and ``selectionUpdatePublisher``.
/// Both streams will receive any updates for text edits or selection changes and a `.finished` completion when the
/// source editor is destroyed.
public class CombineCoordinator: TextViewCoordinator {
    /// Publishes edit notifications as the text is changed in the editor.
    public var textUpdatePublisher: AnyPublisher<Void, Never> {
        updateSubject.eraseToAnyPublisher()
    }

    /// Publishes cursor changes as the user types or selects text.
    public var selectionUpdatePublisher: AnyPublisher<[CursorPosition], Never> {
        selectionSubject.eraseToAnyPublisher()
    }

    private let updateSubject: PassthroughSubject<Void, Never> = .init()
    private let selectionSubject: CurrentValueSubject<[CursorPosition], Never> = .init([])

    /// Initializes the coordinator.
    public init() { }

    public func prepareCoordinator(controller: TextViewController) { }

    public func textViewDidChangeText(controller: TextViewController) {
        updateSubject.send()
    }

    public func textViewDidChangeSelection(controller: TextViewController, newPositions: [CursorPosition]) {
        selectionSubject.send(newPositions)
    }

    public func destroy() {
        updateSubject.send(completion: .finished)
        selectionSubject.send(completion: .finished)
    }
}
