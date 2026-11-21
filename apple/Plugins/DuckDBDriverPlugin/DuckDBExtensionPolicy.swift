//
//  DuckDBExtensionPolicy.swift
//  DuckDBDriverPlugin
//

import CDuckDB
import Foundation

// iOS may not run code it downloads (App Store Review Guideline 2.5.2): its DuckDB links its extensions in
// (scripts/build-duckdb-ios.sh) and installs none. macOS installs and loads a known extension when a statement needs it.
nonisolated enum DuckDBExtensionPolicy {
    #if os(iOS)
    static let openOptions: [(name: String, value: String)] = [
        (name: "autoinstall_known_extensions", value: "false"),
        (name: "autoload_known_extensions", value: "false"),
    ]
    static let sessionStatements: [String] = []

    // DuckDB's generated loader registers them once per process, before the first open.
    private static let registration: Int32 = duckdb_register_static_extensions()

    static func registerLinkedExtensions() {
        _ = registration
    }
    #else
    static let openOptions: [(name: String, value: String)] = []
    static let sessionStatements = ["SET autoinstall_known_extensions=1", "SET autoload_known_extensions=1"]

    static func registerLinkedExtensions() {}
    #endif
}
