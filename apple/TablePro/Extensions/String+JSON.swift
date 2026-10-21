//
//  String+JSON.swift
//  TablePro
//

import Foundation
import TableProTabularIO

extension String {
    // Objects and arrays only: a bare `123` or `"hello"` in a text column is not a document.
    var looksLikeJson: Bool {
        let first = unicodeScalars.first
        guard first == "{" || first == "[" else { return false }
        return isValidJson
    }

    // The RFC 8259 grammar. `JsonSyntaxParser` highlights and accepts `01` or `\q`, and
    // `JSONSerialization` accepts `[1,]` and a leading BOM on macOS 15 and later.
    var isValidJson: Bool {
        var source = self
        return (try? source.withUTF8 { try JSONRowParser.validateValue(in: $0) }) != nil
    }

    func prettyPrintedAsJson() -> String? {
        guard !isEmpty else { return nil }
        return JsonReindenter.reindentIfValid(self)
    }
}
