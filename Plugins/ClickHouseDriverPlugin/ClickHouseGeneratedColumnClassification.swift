//
//  ClickHouseGeneratedColumnClassification.swift
//  ClickHouseDriverPlugin
//

import Foundation

/// ClickHouse reports how a column gets its value in `system.columns.default_kind`.
/// MATERIALIZED and ALIAS columns are computed by the server and reject a written
/// value, so they must stay out of any INSERT. DEFAULT columns take a default when
/// omitted but remain insertable, and an ordinary column reports an empty kind.
internal func clickhouseColumnIsGenerated(defaultKind: String?) -> Bool {
    guard let defaultKind else { return false }
    let kind = defaultKind.trimmingCharacters(in: .whitespaces).uppercased()
    return kind == "MATERIALIZED" || kind == "ALIAS"
}
