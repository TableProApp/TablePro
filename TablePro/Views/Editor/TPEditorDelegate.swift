import AppKit

@MainActor
protocol TPEditorDelegate: AnyObject {
    func editorDidChangeText(_ editor: TPTextView)
    func editorDidChangeSelection(_ editor: TPTextView, range: NSRange)
    func editorShouldComplete(_ editor: TPTextView, at range: NSRange) -> Bool
    func editorDidReceiveKeyDown(_ editor: TPTextView, event: NSEvent) -> Bool
    func editorDidBecomeFirstResponder(_ editor: TPTextView)
    func editorDidResignFirstResponder(_ editor: TPTextView)
}

extension TPEditorDelegate {
    func editorDidChangeText(_ editor: TPTextView) {}
    func editorDidChangeSelection(_ editor: TPTextView, range: NSRange) {}
    func editorShouldComplete(_ editor: TPTextView, at range: NSRange) -> Bool { true }
    func editorDidReceiveKeyDown(_ editor: TPTextView, event: NSEvent) -> Bool { false }
    func editorDidBecomeFirstResponder(_ editor: TPTextView) {}
    func editorDidResignFirstResponder(_ editor: TPTextView) {}
}
