//
//  String+JSON.swift
//  TablePro
//
//  JSON formatting utilities for string values.
//

import Foundation

extension String {
    /// Returns true if this string looks like a JSON object or array (starts with `{`/`[` and parses successfully).
    /// Only checks objects and arrays to avoid false positives with bare primitives like `"hello"`, `123`, `true`.
    var looksLikeJson: Bool {
        let trimmed = unicodeScalars.first
        guard trimmed == "{" || trimmed == "[" else { return false }
        guard let data = data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// Returns a pretty-printed version of this string if it contains valid JSON, or nil otherwise.
    func prettyPrintedAsJson() -> String? {
        guard !isEmpty else { return nil }
        return JsonReindenter.reindentIfValid(self)
    }
}
