//
//  LibPQCopyDirection+UnsupportedMessage.swift
//  PostgreSQLDriverPlugin
//

import Foundation

nonisolated extension LibPQCopyDirection {
    var unsupportedMessage: String {
        switch self {
        case .copyIn:
            return String(localized: "The query editor cannot send data to COPY FROM STDIN, so no rows were sent. Use Import to load a file into a table.")
        case .copyOut:
            return String(localized: "The query editor cannot receive the output of COPY TO STDOUT, so it was discarded. Run a SELECT, or use Export to save the rows to a file.")
        case .copyBoth:
            return String(localized: "The query editor cannot run a replication COPY.")
        }
    }
}
