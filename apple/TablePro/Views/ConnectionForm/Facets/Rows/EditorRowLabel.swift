//
//  EditorRowLabel.swift
//  TablePro
//

import SwiftUI

// A row's title, with its issue as the subtitle once the store reveals it.
struct EditorRowLabel: View {
    private let title: String
    private let row: EditorRow
    @ObservedObject private var store: ConnectionEditorStore
    private let subtitle: String?

    init(_ title: String, row: EditorRow, store: ConnectionEditorStore, subtitle: String? = nil) {
        self.title = title
        self.row = row
        self.store = store
        self.subtitle = subtitle
    }

    var body: some View {
        Text(verbatim: title)
        if let issue = store.revealedIssue(for: row) {
            NoticeLabel(issue.message, severity: issue.noticeSeverity)
        } else if let subtitle {
            Text(verbatim: subtitle)
        }
    }
}

// For a row whose control is the whole row (a list, a code editor), so its issue sits under the control.
struct EditorRowIssueNotice: View {
    let row: EditorRow
    @ObservedObject var store: ConnectionEditorStore

    var body: some View {
        if let issue = store.revealedIssue(for: row) {
            NoticeLabel(issue.message, severity: issue.noticeSeverity)
        }
    }
}

extension FieldIssue {
    var noticeSeverity: NoticeSeverity {
        severity == .error ? .error : .warning
    }
}
