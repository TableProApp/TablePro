//
//  PgpassReader.swift
//  TablePro
//

import Foundation
import os

/// Reads and parses the standard PostgreSQL ~/.pgpass file
enum PgpassReader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PgpassReader")

    /// Whether ~/.pgpass exists
    static func fileExists() -> Bool {
        let path = NSHomeDirectory() + "/.pgpass"
        return FileManager.default.fileExists(atPath: path)
    }

    /// Whether ~/.pgpass has correct permissions (0600). libpq silently ignores the file otherwise.
    static func filePermissionsAreValid() -> Bool {
        let path = NSHomeDirectory() + "/.pgpass"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let posixPerms = attrs[.posixPermissions] as? Int
        else {
            return false
        }
        return posixPerms == 0o600
    }

    /// Resolve a password from ~/.pgpass per PostgreSQL spec.
    /// Returns the password from the first matching entry, or nil if no match.
    /// Format: hostname:port:database:username:password
    /// Wildcard `*` matches any value in a field. First match wins.
    static func resolve(host: String, port: Int, database: String, username: String) -> String? {
        let path = NSHomeDirectory() + "/.pgpass"
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            logger.debug("Could not read ~/.pgpass")
            return nil
        }

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let fields = parseFields(from: trimmed)
            guard fields.count == 5 else { continue }

            if matches(fields[0], value: host)
                && matches(fields[1], value: String(port))
                && matches(fields[2], value: database)
                && matches(fields[3], value: username)
            {
                return fields[4]
            }
        }

        return nil
    }

    /// Parse a pgpass line into fields, handling escaped colons (\:) and backslashes (\\)
    private static func parseFields(from line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var escaped = false

        for char in line {
            if escaped {
                current.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == ":" {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    /// Match a pgpass field value against an actual value. Wildcard "*" matches anything.
    private static func matches(_ pattern: String, value: String) -> Bool {
        pattern == "*" || pattern == value
    }
}
