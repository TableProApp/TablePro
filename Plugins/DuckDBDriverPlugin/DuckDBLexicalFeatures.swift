//
//  DuckDBLexicalFeatures.swift
//  DuckDBDriverPlugin
//

import Foundation
import TableProPluginKit

/// How DuckDB lexes a statement, for the batches the plugin reads itself to track its transaction.
///
/// Measured on 1.5.2 (the linked library) and 1.5.4 (the CLI): `$$` and `$tag$` bodies with non-ASCII tags, nested
/// block comments, `E'...'` escapes, a carriage return ending `--`, and a backslash that never escapes a plain string.
/// The app's curated table holds the same facts and `SQLLexicalFeatureMappingTests` keeps the two equal.
enum DuckDBLexicalFeatures {
    static let features: SQLLexicalFeatures = [
        .taggedDollarQuotes, .nestedBlockComments, .escapeStringPrefix, .carriageReturnEndsLineComments,
    ]
}
