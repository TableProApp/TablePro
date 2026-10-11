//
//  DocumentEditorPresentation.swift
//  TablePro
//

import Foundation

/// What the document sheet shows and allows at each step.
///
/// A write runs under a lease no Stop can interrupt, so while it is on its way the text stays read
/// only and the sheet cannot be dismissed: closing it would not stop the write, only hide its
/// answer. An edit starts by reading the stored document, and until that arrives there is nothing
/// to edit.
struct DocumentEditorPresentation: Equatable {
    enum Phase: Equatable {
        case loading
        case loadFailed(String)
        case missing
        case editing
        case saving
    }

    let isEdit: Bool
    let phase: Phase

    init(kind: DocumentEditorRequest.Kind, phase: Phase) {
        if case .edit = kind {
            isEdit = true
        } else {
            isEdit = false
        }
        self.phase = phase
    }

    static func initialPhase(for kind: DocumentEditorRequest.Kind) -> Phase {
        guard case .edit = kind else { return .editing }
        return .loading
    }

    var title: String {
        isEdit ? String(localized: "Edit Document") : String(localized: "Insert Document")
    }

    var saveTitle: String {
        isEdit ? String(localized: "Save") : String(localized: "Insert")
    }

    var showsEditor: Bool {
        phase == .editing || phase == .saving
    }

    var isEditable: Bool {
        phase == .editing
    }

    var canSave: Bool {
        phase == .editing
    }

    var showsSave: Bool {
        showsEditor
    }

    var canCancel: Bool {
        phase != .saving
    }

    var cancelTitle: String {
        showsEditor || phase == .loading ? String(localized: "Cancel") : String(localized: "Close")
    }

    var dismissDisabled: Bool {
        phase == .saving
    }

    /// Why there is no editor, in place of one.
    var message: String? {
        switch phase {
        case .loadFailed(let reason):
            return reason
        case .missing:
            return String(localized: "This document no longer exists. It was deleted after the grid loaded.")
        case .loading, .editing, .saving:
            return nil
        }
    }

    var hint: String {
        guard isEdit else {
            return String(localized: "Quote every field name. An ObjectId is {\"$oid\": \"…\"} and a date is {\"$date\": \"…\"}.")
        }
        return String(localized: "Save replaces the whole document with this text. A field you remove is removed, and _id cannot change.")
    }
}
