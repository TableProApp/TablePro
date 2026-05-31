import Foundation

public enum PathFieldRole: String, Sendable {
    case database       // standard: URL path = database name
    case serviceName    // Oracle: URL path = service name
    case filePath       // SQLite/DuckDB: URL path = file path
    case databaseIndex  // Redis: URL path = numeric database index
}
