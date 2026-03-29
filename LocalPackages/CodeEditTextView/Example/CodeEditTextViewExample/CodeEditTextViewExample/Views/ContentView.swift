//
//  ContentView.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI

struct ContentView: View {
    @Binding var document: CodeEditTextViewExampleDocument
    @AppStorage("wraplines") private var wrapLines: Bool = true
    @AppStorage("edgeinsets") private var enableEdgeInsets: Bool = false
    @AppStorage("usesystemcursor") private var useSystemCursor: Bool = false
    @AppStorage("isselectable") private var isSelectable: Bool = true
    @AppStorage("iseditable") private var isEditable: Bool = true

    var body: some View {
        SwiftUITextView(
            text: document.text,
            wrapLines: $wrapLines,
            enableEdgeInsets: $enableEdgeInsets,
            useSystemCursor: $useSystemCursor,
            isSelectable: $isSelectable,
            isEditable: $isEditable
        )
        .padding(.bottom, 28)
        .overlay(alignment: .bottom) {
            StatusBar(
                text: document.text,
                wrapLines: $wrapLines,
                enableEdgeInsets: $enableEdgeInsets,
                useSystemCursor: $useSystemCursor,
                isSelectable: $isSelectable,
                isEditable: $isEditable
            )
        }
    }
}

#Preview {
    ContentView(document: .constant(CodeEditTextViewExampleDocument()))
}
