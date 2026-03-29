//
//  SwiftUITextView.swift
//  CodeEditTextViewExample
//
//  Created by Khan Winter on 1/9/25.
//

import SwiftUI
import AppKit
import CodeEditTextView

struct SwiftUITextView: NSViewControllerRepresentable {
    var text: NSTextStorage
    @Binding var wrapLines: Bool
    @Binding var enableEdgeInsets: Bool
    @Binding var useSystemCursor: Bool
    @Binding var isSelectable: Bool
    @Binding var isEditable: Bool

    func makeNSViewController(context: Context) -> TextViewController {
        let controller = TextViewController(string: "")
        controller.textView.setTextStorage(text)
        controller.wrapLines = wrapLines
        controller.enableEdgeInsets = enableEdgeInsets
        controller.useSystemCursor = useSystemCursor
        controller.isSelectable = isSelectable
        controller.isEditable = isEditable
        return controller
    }

    func updateNSViewController(_ nsViewController: TextViewController, context: Context) {
        nsViewController.wrapLines = wrapLines
        nsViewController.enableEdgeInsets = enableEdgeInsets
        nsViewController.useSystemCursor = useSystemCursor
        nsViewController.isSelectable = isSelectable
        nsViewController.isEditable = isEditable
    }
}
