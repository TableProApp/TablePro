//
//  DuckDBStorageCompatibility.swift
//  DuckDBDriverPlugin
//

import Foundation

// DuckDB 2.0 creates files that 1.x cannot open. 1.x's own default keeps every file a connection creates or
// attaches, a .duckdb backup included, readable by DuckDB 1.x. An existing file keeps its version either way.
enum DuckDBStorageCompatibility {
    static let configurationOption = "storage_compatibility_version"
    static let version = "v0.10.2"
}
