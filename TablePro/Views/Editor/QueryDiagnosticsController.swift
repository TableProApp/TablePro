//
//  QueryDiagnosticsController.swift
//  TablePro
//
//  Runs the language's diagnostic producer on a debounce and renders the result as underlines
//  through CodeEditTextView's EmphasisManager, which owns its own drawing layer.
//

import AppKit
import CodeEditSourceEditor
import CodeEditTextView
import os

@MainActor
final class QueryDiagnosticsController {
    static let emphasisGroup = "com.TablePro.queryDiagnostics"

    private var producer: QueryDiagnosticsProducing
    private var pendingTask: Task<Void, Never>?
    private(set) var diagnostics: [QueryDiagnostic] = []
    private lazy var rotorSearch = QueryDiagnosticsRotorSearch { [weak self] in
        self?.diagnostics ?? []
    }

    private static let debounce: Duration = .milliseconds(500)

    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "QueryDiagnostics")

    init(databaseType: DatabaseType?) {
        self.producer = QueryDiagnosticsFactory.make(for: databaseType)
    }

    func configure(databaseType: DatabaseType?) {
        producer = QueryDiagnosticsFactory.make(for: databaseType)
        diagnostics = []
    }

    func install(on controller: TextViewController) {
        guard let textView = controller.textView else { return }
        rotorSearch.textView = textView
        let rotors = textView.accessibilityCustomRotors()
        guard !rotors.contains(where: { $0.itemSearchDelegate === rotorSearch }) else { return }
        let rotor = NSAccessibilityCustomRotor(
            label: QueryDiagnosticsRotorSearch.label,
            itemSearchDelegate: rotorSearch
        )
        textView.setAccessibilityCustomRotors(rotors + [rotor])
    }

    func scheduleRefresh(for controller: TextViewController?) {
        pendingTask?.cancel()

        guard let controller else {
            clear(in: nil)
            return
        }

        pendingTask = Task { [weak self, weak controller] in
            do {
                try await Task.sleep(for: Self.debounce)
            } catch {
                return
            }
            guard !Task.isCancelled, let self, let controller else { return }
            self.refresh(for: controller)
        }
    }

    func refresh(for controller: TextViewController) {
        let text = controller.textView.string
        let produced = producer.diagnostics(for: text)
        guard produced != diagnostics else { return }

        diagnostics = produced
        apply(produced, in: controller)
    }

    func clear(in controller: TextViewController?) {
        pendingTask?.cancel()
        pendingTask = nil
        diagnostics = []
        guard let manager = controller?.textView.emphasisManager,
              !manager.getEmphases(for: Self.emphasisGroup).isEmpty else { return }
        manager.removeEmphases(for: Self.emphasisGroup)
    }

    private func apply(_ produced: [QueryDiagnostic], in controller: TextViewController) {
        guard let manager = controller.textView.emphasisManager else { return }

        let length = (controller.textView.string as NSString).length
        let emphases = produced.compactMap { diagnostic -> Emphasis? in
            guard diagnostic.range.location >= 0,
                  NSMaxRange(diagnostic.range) <= length else { return nil }
            return Emphasis(
                range: diagnostic.range,
                style: .underline(color: color(for: diagnostic.severity)),
                toolTip: diagnostic.message
            )
        }

        manager.replaceEmphases(emphases, for: Self.emphasisGroup)
        Self.logger.debug("diagnostics rendered count=\(emphases.count)")
    }

    private func color(for severity: QueryDiagnostic.Severity) -> NSColor {
        switch severity {
        case .error: return .systemRed
        case .warning: return .systemOrange
        }
    }
}
