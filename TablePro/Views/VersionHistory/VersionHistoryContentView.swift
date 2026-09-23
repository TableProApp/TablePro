//
//  VersionHistoryContentView.swift
//  TablePro
//

import SwiftUI

internal struct VersionHistoryContentView: View {
    let content: String
    let databaseType: DatabaseType
    let exportFileName: String
    let onOpenInEditor: (String) -> Void

    var body: some View {
        ObjectSourceView(
            source: content,
            databaseType: databaseType,
            exportFileName: exportFileName,
            onOpenInEditor: { onOpenInEditor(content) }
        )
    }
}
