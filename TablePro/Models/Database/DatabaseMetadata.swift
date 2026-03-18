//
//  DatabaseMetadata.swift
//  TablePro
//
//  Enhanced database metadata model for the redesigned database switcher.
//  Includes table count, size, last accessed time, and system database detection.
//

import Foundation

/// Metadata for a database including statistics and access information
struct DatabaseMetadata: Identifiable, Equatable {
    let id: String              // Database name (unique identifier)
    let name: String            // Display name
    let tableCount: Int?        // Number of tables in database
    let sizeBytes: Int64?       // Total size in bytes
    let lastAccessed: Date?     // Last time this database was accessed
    let isSystemDatabase: Bool  // Whether this is a system database (mysql, information_schema, etc.)
    let icon: String            // SF Symbol name for icon

    /// Formatted size string (e.g., "14.2 MB")
    var formattedSize: String {
        guard let bytes = sizeBytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Relative time string (e.g., "2 hours ago", "just now")
    var relativeAccessTime: String {
        guard let accessed = lastAccessed else { return "never" }
        return accessed.timeAgoDisplay()
    }

    /// Creates metadata with minimal information (name only)
    static func minimal(name: String, isSystem: Bool = false) -> DatabaseMetadata {
        DatabaseMetadata(
            id: name,
            name: name,
            tableCount: nil,
            sizeBytes: nil,
            lastAccessed: nil,
            isSystemDatabase: isSystem,
            icon: isSystem ? "gearshape.fill" : "cylinder.fill"
        )
    }
}
