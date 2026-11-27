import Foundation

nonisolated public extension LibPQCopyDirection {
    var unsupportedMessage: String {
        switch self {
        case .copyIn:
            return String(localized: "COPY FROM STDIN takes its rows from the lines after the line its ; ends, so no rows were sent.")
        case .copyOut:
            return String(localized: "The query editor cannot receive the output of COPY TO STDOUT, so it was discarded. Run a SELECT, or use Export to save the rows to a file.")
        case .copyBoth:
            return String(localized: "The query editor cannot run a replication COPY.")
        }
    }
}
