//
//  ConnectionEditorFocusTests.swift
//  TableProTests
//

import AppKit
import Foundation
import TableProPluginKit
import TableProSSHConfig
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct ConnectionEditorFocusTests {
    private func makeController(_ fixture: ConnectionEditorStoreFixture) -> ConnectionEditorWindowController {
        ConnectionEditorWindowController(store: fixture.makeStore(.new(type: .postgresql, parsedURL: nil)), frameAutosaveName: nil)
    }

    private func flush(_ window: NSWindow) {
        RunLoop.main.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
    }

    // SwiftUI keeps accessibility identifiers off its AppKit views, so a probe value tells the fields apart.
    private func focusedText(in window: NSWindow) -> String? {
        (window.firstResponder as? NSTextView)?.string
    }

    private func editableField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = editableField(in: subview) { return field }
        }
        return nil
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, !textView.isFieldEditor { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }

    private func escape(in window: NSWindow, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ))
    }

    @Test("A facet built after focus(on:) focuses the requested row, whatever kind of row it is")
    func focusReachesFacetsBuiltLater() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let controller = makeController(fixture)
        defer { controller.close() }
        let store = controller.store
        let window = try #require(controller.window)
        store.selectTransport(.ssh)
        let jumpHost = store.addJumpHost()
        let rule = store.addMaskingRule()
        store.update {
            $0.ssh.host = "probe-ssh-host"
            $0.options.connectTimeoutSeconds = 77
            $0.options.preConnectScript = "probe-pre-connect"
            $0.ssl.clientKeyPath = "/probe/client.key"
            $0.ai.rules = "probe-ai-rules"
            $0.database = "probe_database"
        }
        store.updateMaskingRule(MaskingRule(id: rule, pattern: "probe-pattern"))
        store.updateJumpHost(SSHJumpHost(id: jumpHost, host: "probe-jump-host"))
        flush(window)
        try #require(controller.detail.visitedFacets == [.general])

        let cases: [(ConnectionFacet, EditorRow, String)] = [
            (.sshAndProxies, .builtIn(.sshHost), "probe-ssh-host"),
            (.advanced, .builtIn(.connectTimeout), "77"),
            (.startup, .builtIn(.preConnectScript), "probe-pre-connect"),
            (.sslTLS, .builtIn(.sslClientKey), "/probe/client.key"),
            (.aiAndMCP, .builtIn(.aiRules), "probe-ai-rules"),
            (.safeMode, .builtIn(.maskingRules), "probe-pattern"),
            (.sshAndProxies, .builtIn(.jumpHost(jumpHost)), "probe-jump-host"),
            (.general, .builtIn(.database), "probe_database"),
        ]
        for (facet, row, probe) in cases {
            try #require(store.layout.facet(facet)?.contains(row) == true, "\(row)")
            store.focus(facet: facet, row: row)
            do {
                try await waitUntil(timeout: .seconds(3)) { focusedText(in: window) == probe }
            } catch {
                Issue.record("\(probe): the focused text is \(focusedText(in: window) ?? "nothing")")
            }
            #expect(store.focusRequest == nil, "\(row)")
        }
        #expect(controller.detail.visitedFacets.count == 7)
    }

    @Test("Escape in a text field ends the edit and keeps the window; outside one it is left to Cancel")
    func escapeInTextField() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let controller = makeController(fixture)
        defer { controller.close() }
        let window = try #require(controller.window)
        flush(window)
        let host = try #require(controller.detail.host(for: .general)?.view)
        let field = try #require(editableField(in: host))
        #expect(window.makeFirstResponder(field))
        #expect((window.firstResponder as? NSTextView)?.isFieldEditor == true)

        #expect(!controller.consumesKeyDown(try escape(in: window, modifiers: .shift)))
        #expect(controller.consumesKeyDown(try escape(in: window)))

        #expect(!(window.firstResponder is NSTextView))
        #expect(!controller.store.isClosing)
        #expect(!controller.consumesKeyDown(try escape(in: window)))
    }

    @Test("Escape in a code editor ends the edit and never cancels the window")
    func escapeInCodeEditor() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let controller = makeController(fixture)
        defer { controller.close() }
        let window = try #require(controller.window)
        controller.store.selectedFacet = .startup
        try await waitUntil { controller.detail.shownContent == .facet(.startup) }
        flush(window)
        let host = try #require(controller.detail.host(for: .startup)?.view)
        let editor = try #require(textView(in: host))
        #expect(window.makeFirstResponder(editor))

        #expect(controller.consumesKeyDown(try escape(in: window)))

        #expect(window.firstResponder !== editor)
        #expect(!controller.store.isClosing)
    }

    @Test("Escape with no field being edited reaches Cancel and its close guard")
    func escapeOutsideAFieldCancels() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let clean = makeController(fixture)
        defer { clean.close() }
        let window = try #require(clean.window)
        flush(window)
        window.makeFirstResponder(nil)

        #expect(!clean.consumesKeyDown(try escape(in: window)))
        #expect(window.performKeyEquivalent(with: try escape(in: window)))

        try await waitUntil { clean.store.isClosing }
    }
}
