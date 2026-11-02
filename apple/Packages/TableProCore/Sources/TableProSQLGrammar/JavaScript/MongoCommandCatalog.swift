import Foundation

// An allow-list, since each server release can add a command or alias that destroys (`deleteIndexes`, `bulkWrite`).
public enum MongoCommandCatalog {
    public static let preservingCommands: Set<String> = [
        "ping", "hello", "ismaster", "buildinfo", "hostinfo", "serverstatus", "connectionstatus", "whatsmyuri",
        "listcommands", "getcmdlineopts", "getparameter", "getlog", "currentop", "top", "replsetgetstatus",
        "replsetgetconfig", "connpoolstats", "listdatabases", "listcollections", "listindexes", "dbstats",
        "collstats", "datasize", "validate", "usersinfo", "rolesinfo",
        "find", "getmore", "killcursors", "count", "distinct", "aggregate", "explain", "insert", "update",
        "findandmodify",
        // `collMod` is what Edit View Definition and the validator editor send. A TTL or a capped size empties a
        // collection, so `expiringOptions` decides those two and `createIndexes`.
        "create", "createindexes", "collmod"
    ]

    // An index or collection that holds one of these deletes documents on its own: a TTL monitor, a capped size.
    public static let expiringOptions: Set<String> = ["expireAfterSeconds", "cappedSize", "cappedMax"]

    // Commands that run JavaScript on the server, lowercased; `explain` runs the one it wraps.
    public static let serverCodeCommands: Set<String> = ["mapreduce", "eval", "$eval", "group"]

    // ASCII only: `lowercased()` folds some other letters into ASCII (U+212A to `k`), and the server reads the name as sent.
    public static func preserves(_ name: String) -> Bool {
        name.unicodeScalars.allSatisfy(\.isASCII) && preservingCommands.contains(name.lowercased())
    }
}
