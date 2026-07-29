//
//  RepresentableSyncPhase.swift
//  CodeEditSourceEditor
//
//  Tracks which side of the SwiftUI representable boundary originated the
//  change currently being synchronized, replacing the pair of booleans the
//  coordinator previously juggled. The states are mutually exclusive by
//  construction: an editor change can never be marked while a representable
//  value is being applied, and a representable value is never applied while
//  an editor change is pending.
//

import Foundation

@MainActor
final class RepresentableSyncPhase {
    enum Phase: Equatable {
        case idle
        case editorChangePending
        case applyingRepresentableValue
    }

    private(set) var phase: Phase = .idle

    var isEditorChangePending: Bool {
        phase == .editorChangePending
    }

    var isApplyingRepresentableValue: Bool {
        phase == .applyingRepresentableValue
    }

    /// Latches that the editor originated a change. The next representable
    /// update pass consumes this instead of pushing its own values down.
    /// Ignored while a representable value is being applied, since editor
    /// notifications fired during a programmatic application are echoes,
    /// not user edits.
    func markEditorChange() {
        guard phase != .applyingRepresentableValue else { return }
        phase = .editorChangePending
    }

    /// Returns whether an editor change was pending and resets to idle.
    @discardableResult
    func consumePendingEditorChange() -> Bool {
        guard phase == .editorChangePending else { return false }
        phase = .idle
        return true
    }

    /// Runs `body` with the phase marked as applying a representable value,
    /// so editor notifications fired by the application itself are ignored.
    func applyRepresentableValue(_ body: () -> Void) {
        let previous = phase
        phase = .applyingRepresentableValue
        body()
        phase = previous
    }
}
