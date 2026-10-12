//
//  AgentResultSegment.swift
//  TablePro
//

import Foundation

/// Which of its two views the result column shows.
///
/// Two, because two are all a transcript can fill: the statements a session proposed, and the rows
/// its queries read. The column used to offer a plan and a schema view beside them, and neither had
/// anything in `AgentArtifact` to draw from, so half the choice was two empty states that could never
/// fill.
internal enum AgentResultSegment: String, CaseIterable, Hashable {
    case sql
    case results

    internal var title: String {
        switch self {
        case .sql: String(localized: "SQL")
        case .results: String(localized: "Results")
        }
    }

    internal var symbolName: String {
        switch self {
        case .sql: "curlybraces"
        case .results: "tablecells"
        }
    }
}
