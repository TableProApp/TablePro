import Foundation
import os

public enum PgpassReader {
    private static let logger = Logger(subsystem: "com.TablePro", category: "PgpassReader")

    public static func fileExists() -> Bool {
        let path = NSHomeDirectory() + "/.pgpass"
        return FileManager.default.fileExists(atPath: path)
    }

    /// libpq silently ignores a ~/.pgpass whose mode is not 0600.
    public static func filePermissionsAreValid() -> Bool {
        let path = NSHomeDirectory() + "/.pgpass"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let posixPerms = attrs[.posixPermissions] as? Int
        else {
            return false
        }
        return posixPerms == 0o600
    }

    /// libpq resolves an unset user to the operating system login name before matching ~/.pgpass,
    /// so a blank username field must resolve the same way here.
    public static func effectiveUsername(_ username: String) -> String {
        username.isEmpty ? NSUserName() : username
    }

    /// libpq's rules: `*` matches any value in a field, and the first matching line wins.
    public static func resolve(host: String, port: Int, database: String, username: String) -> String? {
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
