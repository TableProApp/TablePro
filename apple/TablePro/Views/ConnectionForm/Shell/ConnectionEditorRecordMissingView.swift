//
//  ConnectionEditorRecordMissingView.swift
//  TablePro
//

import SwiftUI

// An edit of a connection the library no longer holds: nothing to show and nothing Save could write.
struct ConnectionEditorRecordMissingView: View {
    let onClose: () -> Void

    var body: some View {
        UnavailableStateView {
            Label(String(localized: "Connection Not Found"), systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(String(localized: "This connection was deleted on another device or window."))
        } actions: {
            Button(String(localized: "Close"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("connection-form-record-missing-close")
        }
    }
}
