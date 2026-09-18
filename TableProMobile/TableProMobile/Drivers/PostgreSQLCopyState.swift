import Foundation

nonisolated extension LibPQCopyDirection {
    var unsupportedMessage: String {
        switch self {
        case .copyIn:
            return String(localized: "TablePro cannot send data to COPY FROM STDIN, so no rows were sent. Insert the rows with INSERT instead.")
        case .copyOut:
            return String(localized: "TablePro cannot receive the output of COPY TO STDOUT, so it was discarded. Run a SELECT instead.")
        case .copyBoth:
            return String(localized: "TablePro cannot run a replication COPY.")
        }
    }
}
