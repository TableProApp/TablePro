//
//  QueryDiagnosticsRefreshTests.swift
//  TableProTests
//

import AppKit
@testable import CodeEditSourceEditor
@testable import CodeEditTextView
import Foundation
import SwiftUI
@testable import TablePro
import Testing

@MainActor
private final class DocumentReplacementRecorder: TextViewCoordinator {
    private(set) var replacedDocuments: [String] = []

    func prepareCoordinator(controller: TextViewController) {}

    func textViewDidReplaceDocument(controller: TextViewController) {
        replacedDocuments.append(controller.textView.string)
    }
}

@MainActor
@Suite("Query diagnostics refresh")
struct QueryDiagnosticsRefreshTests {
    private func makeEditor(_ text: String = "") -> (SQLEditorCoordinator, TextViewController) {
        let coordinator = SQLEditorCoordinator()
        coordinator.databaseType = .mysql
        let controller = EditorControllerFixture.make(string: text, coordinators: [coordinator])
        return (coordinator, controller)
    }

    private func underlines(in controller: TextViewController) -> [NSRange] {
        controller.textView.emphasisManager?
            .getEmphases(for: QueryDiagnosticsController.emphasisGroup)
            .map(\.range) ?? []
    }

    private func waitForUnderlines(
        in controller: TextViewController,
        timeout: Duration = .seconds(5)
    ) async -> [NSRange] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let ranges = underlines(in: controller)
            if !ranges.isEmpty { return ranges }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return underlines(in: controller)
    }

    @Test("Replacing the document tells every coordinator, and an edit does not")
    func setTextNotifiesCoordinators() {
        let recorder = DocumentReplacementRecorder()
        let controller = EditorControllerFixture.make(string: "SELECT 1", coordinators: [recorder])

        controller.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: ";")
        #expect(recorder.replacedDocuments.isEmpty)

        controller.setText("SELECT 2")
        #expect(recorder.replacedDocuments == ["SELECT 2"])
    }

    @Test("A replaced document is checked without a keystroke")
    func replacedDocumentIsChecked() async {
        let (coordinator, controller) = makeEditor("SELECT 1")
        defer { coordinator.destroy() }

        controller.setText("SELECT 2))")

        #expect(await waitForUnderlines(in: controller) == [NSRange(location: 8, length: 1)])
    }

    @Test("The previous document's underline goes the moment the document is replaced")
    func staleUnderlineIsDropped() async throws {
        let (coordinator, controller) = makeEditor("SELECT 1")
        defer { coordinator.destroy() }
        controller.textView.replaceCharacters(in: NSRange(location: 8, length: 0), with: ")")
        #expect(await waitForUnderlines(in: controller) == [NSRange(location: 8, length: 1)])

        controller.setText("SELECT name FROM t")

        #expect(underlines(in: controller).isEmpty)
        try await Task.sleep(for: .milliseconds(800))
        #expect(underlines(in: controller).isEmpty)
    }

    @Test("A tab switch pushed through the text binding re-checks the incoming tab")
    func tabSwitchThroughBinding() async {
        let (coordinator, controller) = makeEditor()
        defer { coordinator.destroy() }
        let sync = TextBindingSync(text: .binding(.constant("")), phase: RepresentableSyncPhase())
        sync.applyRepresentableText("SELECT 1)", controller: controller)
        #expect(await waitForUnderlines(in: controller) == [NSRange(location: 8, length: 1)])

        sync.applyRepresentableText("SELECT name FROM t /* open", controller: controller)

        #expect(underlines(in: controller).isEmpty)
        #expect(await waitForUnderlines(in: controller) == [NSRange(location: 19, length: 2)])
    }

    @Test("An underline below the lines on screen is drawn once its line lays out")
    func underlineBelowTheViewportIsDrawn() async throws {
        let (coordinator, controller) = makeEditor("SELECT 1")
        defer { coordinator.destroy() }
        let statements = (1...200).map { "SELECT \($0);" } + ["SELECT 201)"]
        controller.setText(statements.joined(separator: "\n"))
        let range = try #require(await waitForUnderlines(in: controller).first)

        let textView = try #require(controller.textView)
        textView.layoutManager.layoutLines(in: CGRect(origin: .zero, size: CGSize(width: 1_000, height: 20_000)))
        textView.emphasisManager?.updateLayerBackgrounds()

        let line = try #require(textView.layoutManager.rectsFor(range: range).first)
        let underlines = (textView.layer?.sublayers ?? []).compactMap { $0 as? CAShapeLayer }.filter { layer in
            guard !layer.isHidden, let bounds = layer.path?.boundingBox else { return false }
            return abs(bounds.minX - line.minX) < 1 && bounds.midY >= line.minY && bounds.midY <= line.maxY
        }
        #expect(underlines.count == 1)
    }

    @Test("The statement run controls follow a replaced document")
    func runControlsFollowReplacedDocument() {
        let (coordinator, controller) = makeEditor("SELECT 1;")
        defer { coordinator.destroy() }

        controller.setText("SELECT 1;\nSELECT 2;\nSELECT 3;")

        #expect(controller.runnableStatements.count == 3)
    }
}

@MainActor
@Suite("Query diagnostic messages")
struct QueryDiagnosticMessageTests {
    private func makeChecked(_ text: String) -> (QueryDiagnosticsController, TextViewController) {
        let controller = EditorControllerFixture.make(string: text)
        let diagnostics = QueryDiagnosticsController(databaseType: .mysql)
        diagnostics.install(on: controller)
        diagnostics.refresh(for: controller)
        controller.textView.emphasisManager?.updateLayerBackgrounds()
        return (diagnostics, controller)
    }

    private func center(of range: NSRange, in controller: TextViewController) throws -> CGPoint {
        let rect = try #require(controller.textView.layoutManager.rectsFor(range: range).first)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func rotor(in controller: TextViewController) throws -> NSAccessibilityCustomRotor {
        try #require(
            controller.textView.accessibilityCustomRotors().first { $0.label == QueryDiagnosticsRotorSearch.label }
        )
    }

    private func search(
        _ rotor: NSAccessibilityCustomRotor,
        in element: NSView,
        from current: NSRange?,
        direction: NSAccessibilityCustomRotor.SearchDirection = .next,
        filter: String = ""
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        let parameters = NSAccessibilityCustomRotor.SearchParameters()
        parameters.searchDirection = direction
        parameters.filterString = filter
        if let current {
            let item = NSAccessibilityCustomRotor.ItemResult(targetElement: element)
            item.targetRange = current
            parameters.currentItem = item
        }
        return rotor.itemSearchDelegate?.rotor(rotor, resultFor: parameters)
    }

    @Test("Resting the pointer on an underline shows its message")
    func toolTipOverUnderline() throws {
        let (_, controller) = makeChecked("SELECT 1)")
        let manager = try #require(controller.textView.emphasisManager)

        let underlined = try center(of: NSRange(location: 8, length: 1), in: controller)
        let plain = try center(of: NSRange(location: 0, length: 6), in: controller)

        #expect(manager.toolTip(at: underlined) == "No matching opening bracket")
        #expect(manager.toolTip(at: plain) == nil)
    }

    @Test("A cleared diagnostic takes its message with it")
    func clearedDiagnosticDropsToolTip() throws {
        let (diagnostics, controller) = makeChecked("SELECT 1)")
        let manager = try #require(controller.textView.emphasisManager)
        let underlined = try center(of: NSRange(location: 8, length: 1), in: controller)

        diagnostics.clear(in: controller)

        #expect(manager.toolTip(at: underlined) == nil)
    }

    @Test("Clearing with nothing underlined leaves the editor's layout alone")
    func clearWithoutUnderlinesDoesNotForceLayout() throws {
        let controller = EditorControllerFixture.make(string: "SELECT 1")
        let diagnostics = QueryDiagnosticsController(databaseType: .mysql)
        let layer = try #require(controller.textView.layer)
        layer.setNeedsLayout()

        diagnostics.clear(in: controller)

        #expect(layer.needsLayout())
    }

    @Test("The rotor walks every problem in document order with its message")
    func rotorWalksProblems() throws {
        let (diagnostics, controller) = makeChecked("SELECT 1) /* open")
        let rotor = try rotor(in: controller)
        #expect(diagnostics.diagnostics.count == 2)

        let first = try #require(search(rotor, in: controller.textView, from: nil))
        #expect(first.targetRange == NSRange(location: 8, length: 1))
        #expect(first.customLabel == "No matching opening bracket")
        #expect(first.targetElement === controller.textView)

        let second = try #require(search(rotor, in: controller.textView, from: first.targetRange))
        #expect(second.targetRange == NSRange(location: 10, length: 2))
        #expect(second.customLabel == "Unterminated comment")

        #expect(search(rotor, in: controller.textView, from: second.targetRange) == nil)
        let previous = search(rotor, in: controller.textView, from: second.targetRange, direction: .previous)
        #expect(previous?.targetRange == first.targetRange)
    }

    @Test("The rotor filters by message")
    func rotorFiltersByMessage() throws {
        let (diagnostics, controller) = makeChecked("SELECT 1) /* open")
        let rotor = try rotor(in: controller)
        #expect(diagnostics.diagnostics.count == 2)

        let found = try #require(search(rotor, in: controller.textView, from: nil, filter: "comment"))

        #expect(found.targetRange == NSRange(location: 10, length: 2))
    }

    @Test("A document with no problems gives the rotor nothing to find")
    func rotorEmptyWithoutProblems() throws {
        let (diagnostics, controller) = makeChecked("SELECT 1")
        let rotor = try rotor(in: controller)

        #expect(diagnostics.diagnostics.isEmpty)
        #expect(search(rotor, in: controller.textView, from: nil) == nil)
    }

    @Test("Installing twice leaves one rotor")
    func rotorInstalledOnce() {
        let (diagnostics, controller) = makeChecked("SELECT 1")

        diagnostics.install(on: controller)

        let rotors = controller.textView.accessibilityCustomRotors()
        #expect(rotors.filter { $0.label == QueryDiagnosticsRotorSearch.label }.count == 1)
    }
}

private extension EmphasisManager {
    @MainActor
    func toolTip(at point: CGPoint) -> String? {
        guard let textView else { return nil }
        let text = toolTips.view(textView, stringForToolTip: 0, point: point, userData: nil)
        return text.isEmpty ? nil : text
    }
}
