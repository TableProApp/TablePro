//
//  CodeEditSourceEditorExampleApp.swift
//  CodeEditSourceEditorExample
//
//  Created by Khan Winter on 2/24/24.
//

import SwiftUI

@main
struct CodeEditSourceEditorExampleApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: CodeEditSourceEditorExampleDocument()) { file in
            ContentView(document: file.$document, fileURL: file.fileURL)
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
