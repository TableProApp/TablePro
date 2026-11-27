//
//  DuckDBLexicalFeatures.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

// Measured on 2.0.0, the linked library: `$$` and `$tag$` bodies with non-ASCII tags, nested block comments,
// `E'...'` escapes, backtick-quoted names, a carriage return ending `--`, and a backslash that never escapes a plain
// string or a name. The app's curated table holds the same facts.
nonisolated enum DuckDBLexicalFeatures {
    static let features: SQLLexicalFeatures = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .backtickQuotes,
        .carriageReturnEndsLineComments,
    ]
}
