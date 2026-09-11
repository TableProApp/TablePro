//
//  QueryDiagnosticsRotorSearch.swift
//  TablePro
//

import AppKit

@MainActor
final class QueryDiagnosticsRotorSearch: NSObject, @MainActor NSAccessibilityCustomRotorItemSearchDelegate {
    static var label: String {
        String(localized: "Query Issues")
    }

    weak var textView: NSView?
    private let diagnostics: () -> [QueryDiagnostic]

    init(diagnostics: @escaping () -> [QueryDiagnostic]) {
        self.diagnostics = diagnostics
    }

    func rotor(
        _ rotor: NSAccessibilityCustomRotor,
        resultFor searchParameters: NSAccessibilityCustomRotor.SearchParameters
    ) -> NSAccessibilityCustomRotor.ItemResult? {
        guard let textView else { return nil }
        let candidates = matching(searchParameters.filterString)
        let start = searchParameters.currentItem?.targetRange.location ?? NSNotFound
        let found = searchParameters.searchDirection == .previous
            ? candidates.last { start == NSNotFound || $0.range.location < start }
            : candidates.first { start == NSNotFound || $0.range.location > start }
        guard let found else { return nil }

        let result = NSAccessibilityCustomRotor.ItemResult(targetElement: textView)
        result.targetRange = found.range
        result.customLabel = found.message
        return result
    }

    private func matching(_ filter: String) -> [QueryDiagnostic] {
        let sorted = diagnostics().sorted { $0.range.location < $1.range.location }
        guard !filter.isEmpty else { return sorted }
        return sorted.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }
}
