//
//  NSViewFocusTests.swift
//  TableProTests
//

import AppKit
import Testing
@testable import TablePro

@Suite("NSView+Focus")
struct NSViewFocusTests {
    @Test("Returns nil for empty container view")
    func emptyView() {
        let container = NSView(frame: .zero)
        #expect(container.firstEditableTextField() == nil)
    }

    @Test("Finds direct editable text field")
    func directTextField() {
        let textField = NSTextField(frame: .zero)
        #expect(textField.firstEditableTextField() === textField)
    }

    @Test("Finds editable text field in subviews")
    func nestedTextField() {
        let container = NSView(frame: .zero)
        let child = NSView(frame: .zero)
        let textField = NSTextField(frame: .zero)
        child.addSubview(textField)
        container.addSubview(child)
        #expect(container.firstEditableTextField() === textField)
    }

    @Test("Skips non-editable text field")
    func skipsNonEditable() {
        let container = NSView(frame: .zero)
        let label = NSTextField(labelWithString: "Label")
        container.addSubview(label)
        #expect(container.firstEditableTextField() == nil)
    }

    @Test("Returns first editable text field in depth-first order")
    func depthFirstOrder() {
        let container = NSView(frame: .zero)
        let first = NSTextField(frame: .zero)
        let second = NSTextField(frame: .zero)
        container.addSubview(first)
        container.addSubview(second)

        let found = container.firstEditableTextField()
        #expect(found === first)
    }

    @Test("Finds editable text field among mixed subviews")
    func mixedSubviews() {
        let container = NSView(frame: .zero)
        let button = NSButton(frame: .zero)
        let label = NSTextField(labelWithString: "Label")
        let editable = NSTextField(frame: .zero)

        container.addSubview(button)
        container.addSubview(label)
        container.addSubview(editable)

        #expect(container.firstEditableTextField() === editable)
    }

    @Test("Returns nil when only non-editable text fields exist")
    func onlyLabels() {
        let container = NSView(frame: .zero)
        let label1 = NSTextField(labelWithString: "A")
        let label2 = NSTextField(labelWithString: "B")
        container.addSubview(label1)
        container.addSubview(label2)
        #expect(container.firstEditableTextField() == nil)
    }

    @Test("Finds deeply nested text field")
    func deeplyNested() {
        let root = NSView(frame: .zero)
        var current = root
        for _ in 0 ..< 5 {
            let child = NSView(frame: .zero)
            current.addSubview(child)
            current = child
        }
        let textField = NSTextField(frame: .zero)
        current.addSubview(textField)

        #expect(root.firstEditableTextField() === textField)
    }
}
