//
//  ConcurrentRefreshNoteView.swift
//  TablePro
//

import SwiftUI

struct ConcurrentRefreshNoteView: View {
    let note: MaterializedViewConcurrentRefreshNote

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Label(note.text, systemImage: note.systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .accessibilityIdentifier("structure-concurrent-refresh-note")
        }
    }
}
