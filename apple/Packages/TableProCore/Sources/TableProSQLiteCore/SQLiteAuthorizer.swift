import CSQLite
import Foundation

// `fts3_tokenizer` dereferences a pointer from a bound blob (measured: SIGSEGV) and `load_extension` loads a library,
// so every SQLite handle either plugin opens denies both. Extensions the user lists load through the C API, which the
// authorizer does not see.
public enum SQLiteAuthorizer {
    private static let callback: @convention(c) (
        UnsafeMutableRawPointer?, Int32,
        UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?
    ) -> Int32 = { context, action, arg1, arg2, _, _ in
        let policy = context.map { Unmanaged<SQLiteAuthorizerPolicy>.fromOpaque($0).takeUnretainedValue() }
        let scope = policy?.scope ?? .unrestricted
        // SQLITE_READ comes once per column read, so an unrestricted statement converts no table name.
        let restricted = scope != .unrestricted
        let readsFirst = switch action {
        case SQLITE_PRAGMA, SQLITE_ATTACH: true
        case SQLITE_READ, SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE: restricted
        default: false
        }
        let readsSecond = action == SQLITE_FUNCTION
            || (restricted && (action == SQLITE_CREATE_VTABLE || action == SQLITE_DROP_VTABLE))
        return SQLiteAuthorizerPolicy.decision(
            action: action,
            first: readsFirst ? arg1.map { String(cString: $0) } : nil,
            second: readsSecond ? arg2.map { String(cString: $0) } : nil,
            scope: scope,
            extensions: policy?.extensions ?? .empty
        )
    }

    public static func install(on db: OpaquePointer?) {
        sqlite3_set_authorizer(db, callback, nil)
    }

    // The handle keeps an unretained pointer: the caller holds `policy` until the handle is closed.
    public static func install(on db: OpaquePointer?, policy: SQLiteAuthorizerPolicy) {
        sqlite3_set_authorizer(db, callback, Unmanaged.passUnretained(policy).toOpaque())
    }
}

public enum SQLiteStatementScope: Sendable, Equatable {
    case unrestricted
    // An extension function can write files, and ATTACH or VACUUM INTO creates one.
    case noServerCode
    case readOnly
}

// What loading the user's extensions added to a handle, lowercased.
public struct SQLiteExtensionNames: Sendable, Equatable {
    // Nil when the list could not be read, so a restricted scope allows no function at all.
    public var functions: Set<String>?
    // Nil when the list could not be read, so a restricted scope reads and writes no table at all.
    public var modules: Set<String>?

    public init(functions: Set<String>?, modules: Set<String>?) {
        self.functions = functions
        self.modules = modules
    }

    public static let empty = SQLiteExtensionNames(functions: [], modules: [])
}

public final class SQLiteAuthorizerPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var currentScope: SQLiteStatementScope
    public let extensions: SQLiteExtensionNames

    public init(extensions: SQLiteExtensionNames, scope: SQLiteStatementScope = .unrestricted) {
        self.extensions = extensions
        self.currentScope = scope
    }

    public var scope: SQLiteStatementScope {
        get { lock.withLock { currentScope } }
        set { lock.withLock { currentScope = newValue } }
    }

    // The names `load` adds to the handle. A list of what is allowed would not do: ALTER TABLE calls internal
    // functions such as `sqlite_rename_table`, which `PRAGMA function_list` never lists (measured on 3.53.4).
    public static func extensionNames(on db: OpaquePointer, load: () throws -> Void) rethrows -> SQLiteExtensionNames {
        let functionsBefore = names(on: db, pragma: "PRAGMA function_list")
        let modulesBefore = names(on: db, pragma: "PRAGMA module_list")
        try load()
        return SQLiteExtensionNames(
            functions: added(after: names(on: db, pragma: "PRAGMA function_list"), before: functionsBefore),
            modules: added(after: names(on: db, pragma: "PRAGMA module_list"), before: modulesBefore)
        )
    }

    private static func added(after: Set<String>?, before: Set<String>?) -> Set<String>? {
        guard let before, let after else { return nil }
        return after.subtracting(before)
    }

    // These pragmas read no schema, so a file that is not a database still answers.
    private static func names(on db: OpaquePointer, pragma: String) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragma, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) {
                names.insert(String(cString: name).lowercased())
            }
            step = sqlite3_step(statement)
        }
        return step == SQLITE_DONE ? names : nil
    }

    private static let alwaysDenied: Set<String> = ["fts3_tokenizer", "load_extension"]

    // Pragmas that only report, whatever their argument names. Any other one can change the database, the
    // connection or the process (`hard_heap_limit`), and SQLite applies it while compiling.
    private static let reportingPragmas: Set<String> = [
        "table_info", "table_xinfo", "table_list", "index_info", "index_xinfo", "index_list",
        "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check", "function_list",
        "pragma_list", "module_list", "collation_list", "database_list", "compile_options",
        // FTS5 runs it on every read of its table.
        "data_version",
    ]

    static func decision(
        action: Int32,
        first: String?,
        second: String?,
        scope: SQLiteStatementScope,
        extensions: SQLiteExtensionNames
    ) -> Int32 {
        let function = action == SQLITE_FUNCTION ? second?.lowercased() : nil
        if let function, alwaysDenied.contains(function) { return SQLITE_DENY }
        guard scope != .unrestricted else { return SQLITE_OK }
        let isExtensionFunction = function.map { extensions.functions?.contains($0) ?? true } ?? false
        switch action {
        // An extension's eponymous virtual table, such as fileio's `fsdir`, runs its code with no function call;
        // `SELECT count(*)` reads it with an empty column name.
        case SQLITE_READ, SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
            if isExtensionModule(first, in: extensions) { return SQLITE_DENY }
        case SQLITE_CREATE_VTABLE, SQLITE_DROP_VTABLE:
            if isExtensionModule(second, in: extensions) { return SQLITE_DENY }
        default:
            break
        }
        switch scope {
        case .unrestricted:
            return SQLITE_OK
        case .noServerCode:
            switch action {
            case SQLITE_ATTACH:
                // Plain VACUUM attaches the literal ''; a filename that is an expression arrives as nil.
                return first == "" ? SQLITE_OK : SQLITE_DENY
            case SQLITE_DETACH:
                return SQLITE_DENY
            case SQLITE_FUNCTION:
                return isExtensionFunction ? SQLITE_DENY : SQLITE_OK
            default:
                return SQLITE_OK
            }
        case .readOnly:
            switch action {
            case SQLITE_ATTACH, SQLITE_DETACH, SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
                return SQLITE_DENY
            case SQLITE_PRAGMA:
                return first.map { reportingPragmas.contains($0.lowercased()) } == true ? SQLITE_OK : SQLITE_DENY
            case SQLITE_FUNCTION:
                return isExtensionFunction ? SQLITE_DENY : SQLITE_OK
            default:
                return SQLITE_OK
            }
        }
    }

    private static func isExtensionModule(_ name: String?, in extensions: SQLiteExtensionNames) -> Bool {
        guard let modules = extensions.modules else { return true }
        return name.map { modules.contains($0.lowercased()) } ?? false
    }
}
