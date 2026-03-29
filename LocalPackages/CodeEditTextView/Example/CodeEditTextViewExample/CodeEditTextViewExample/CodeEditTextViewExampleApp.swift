//
//  CodeEditTextViewExampleApp.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI

@main
struct CodeEditTextViewExampleApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: CodeEditTextViewExampleDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
