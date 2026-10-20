import Foundation
import TableProModels

nonisolated enum OpenTransactionWarning {
    static func reconnectingOnSave(connectionName: String) -> String {
        String(
            format: String(
                localized: "Saving reconnects “%@”, which has an open transaction. Reconnecting rolls it back and discards its uncommitted changes."
            ),
            connectionName
        )
    }

    static func deletion(deletingCount: Int, holdingTransactions names: [String], locale: Locale = .current) -> String {
        let credentials = deletingCount > 1
            ? String(localized: "Saved credentials for these connections will be permanently removed.")
            : String(localized: "Are you sure you want to delete this connection? Saved credentials will be permanently removed.")
        let transactions: String
        switch names.count {
        case 0:
            return credentials
        case 1:
            transactions = String(
                format: String(
                    localized: "“%@” has an open transaction. Deleting the connection rolls it back and discards its uncommitted changes."
                ),
                names[0]
            )
        default:
            let formatter = ListFormatter()
            formatter.locale = locale
            let quoted = names.map { "“\($0)”" }
            transactions = String(
                format: String(
                    localized: "These connections have open transactions: %@. Deleting them rolls the transactions back and discards their uncommitted changes."
                ),
                formatter.string(from: quoted) ?? quoted.joined(separator: ", ")
            )
        }
        return "\(transactions) \(credentials)"
    }

    // These engines commit the open transaction before any DDL statement runs.
    static func ddlCommitsTransaction(on type: DatabaseType) -> Bool {
        [DatabaseType.mysql, .mariadb, .tidb, .oceanbase, .oracle].contains(type)
    }

    static func ddlConfirmation(_ message: String, type: DatabaseType, holdsTransaction: Bool) -> String {
        guard holdsTransaction, ddlCommitsTransaction(on: type) else { return message }
        let commits = String(localized: "This also commits the open transaction, keeping its uncommitted changes.")
        return "\(message) \(commits)"
    }
}
