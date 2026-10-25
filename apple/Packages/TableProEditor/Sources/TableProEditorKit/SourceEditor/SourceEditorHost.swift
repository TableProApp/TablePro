//
//  SourceEditorHost.swift
//  TableProEditorKit
//

import AppKit
import SwiftUI

/// ``SourceEditor`` for an AppKit container: the same controller, two-way sync and teardown, with no SwiftUI host
/// around the editor.
@MainActor
public final class SourceEditorHost {
    public let controller: TextViewController
    /// Runs when the editor writes its state, before the write is applied back, as `onChange` does in SwiftUI.
    public var onStateChange: ((_ old: SourceEditorState, _ new: SourceEditorState) -> Void)?

    private let box: StateBox
    private let coordinator: SourceEditor.Coordinator
    private var editor: SourceEditor

    public var state: SourceEditorState { box.state }

    public init(state: SourceEditorState = SourceEditorState(), _ makeEditor: (Binding<SourceEditorState>) -> SourceEditor) {
        let box = StateBox(state: state)
        let editor = makeEditor(box.binding)
        let coordinator = editor.makeCoordinator()
        self.box = box
        self.editor = editor
        self.coordinator = coordinator
        controller = editor.makeController(coordinator: coordinator)
        box.onWrite = { [weak self] old, new in self?.stateDidChange(from: old, to: new) }
    }

    public func update(_ makeEditor: (Binding<SourceEditorState>) -> SourceEditor) {
        editor = makeEditor(box.binding)
        editor.update(controller, coordinator: coordinator)
    }

    public func dismantle() {
        SourceEditor.dismantleNSViewController(controller, coordinator: coordinator)
    }

    // A SwiftUI state write leads to an update pass that consumes the editor's change latch; without one the latch
    // would swallow the next text the owner pushes.
    private func stateDidChange(from old: SourceEditorState, to new: SourceEditorState) {
        onStateChange?(old, new)
        editor.update(controller, coordinator: coordinator)
    }
}

@MainActor
private final class StateBox {
    var state: SourceEditorState
    var onWrite: ((SourceEditorState, SourceEditorState) -> Void)?

    init(state: SourceEditorState) {
        self.state = state
    }

    var binding: Binding<SourceEditorState> {
        Binding(
            get: { [weak self] in self?.state ?? SourceEditorState() },
            set: { [weak self] newValue in
                guard let self else { return }
                let old = state
                state = newValue
                onWrite?(old, newValue)
            }
        )
    }
}
