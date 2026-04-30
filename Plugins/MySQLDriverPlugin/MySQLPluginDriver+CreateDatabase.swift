import Foundation
import TableProPluginKit

extension MySQLPluginDriver {
    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        let charsetDefaults = try await fetchCharsetDefaults()
        let collations = try await fetchCollationCatalog()
        let serverDefaults = await fetchServerCharsetDefaults()

        guard !charsetDefaults.isEmpty, !collations.isEmpty else {
            return nil
        }

        let resolvedCharset = serverDefaults.charset ?? charsetDefaults.first?.charset
        let charsetOptions = charsetDefaults.map { entry -> PluginCreateDatabaseFormSpec.Option in
            let isServerDefault = entry.charset == serverDefaults.charset
            return PluginCreateDatabaseFormSpec.Option(
                value: entry.charset,
                label: entry.charset,
                subtitle: isServerDefault ? String(localized: "(server default)") : nil,
                group: nil
            )
        }

        let collationOptions = collations.map { entry -> PluginCreateDatabaseFormSpec.Option in
            let isServerDefault = entry.collation == serverDefaults.collation
            return PluginCreateDatabaseFormSpec.Option(
                value: entry.collation,
                label: entry.collation,
                subtitle: isServerDefault ? String(localized: "(server default)") : nil,
                group: entry.charset
            )
        }

        let collationDefault: String? = {
            if let serverCollation = serverDefaults.collation,
               collations.contains(where: { $0.collation == serverCollation }) {
                return serverCollation
            }
            guard let chosenCharset = resolvedCharset else { return nil }
            return charsetDefaults.first(where: { $0.charset == chosenCharset })?.defaultCollation
        }()

        let charsetField = PluginCreateDatabaseFormSpec.Field(
            id: "charset",
            label: String(localized: "Character Set"),
            kind: .picker(options: charsetOptions, defaultValue: resolvedCharset)
        )

        let collationField = PluginCreateDatabaseFormSpec.Field(
            id: "collation",
            label: String(localized: "Collation"),
            kind: .searchable(options: collationOptions, defaultValue: collationDefault),
            groupedBy: "charset"
        )

        return PluginCreateDatabaseFormSpec(fields: [charsetField, collationField], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        guard let charset = request.values["charset"], !charset.isEmpty else {
            throw MariaDBPluginError(
                code: 0,
                message: String(localized: "Character set is required"),
                sqlState: nil
            )
        }

        guard isSafeCharsetIdentifier(charset) else {
            throw MariaDBPluginError(
                code: 0,
                message: String(format: String(localized: "Invalid character set: %@"), charset),
                sqlState: nil
            )
        }

        let availableCharsets = try await fetchCharsetDefaults().map(\.charset)
        guard availableCharsets.contains(charset) else {
            throw MariaDBPluginError(
                code: 0,
                message: String(format: String(localized: "Unknown character set: %@"), charset),
                sqlState: nil
            )
        }

        let collationValue = request.values["collation"].flatMap { $0.isEmpty ? nil : $0 }

        if let collation = collationValue {
            guard isSafeCharsetIdentifier(collation) else {
                throw MariaDBPluginError(
                    code: 0,
                    message: String(format: String(localized: "Invalid collation: %@"), collation),
                    sqlState: nil
                )
            }

            let collations = try await fetchCollationCatalog()
            guard let match = collations.first(where: { $0.collation == collation }) else {
                throw MariaDBPluginError(
                    code: 0,
                    message: String(format: String(localized: "Unknown collation: %@"), collation),
                    sqlState: nil
                )
            }
            guard match.charset == charset else {
                throw MariaDBPluginError(
                    code: 0,
                    message: String(
                        format: String(localized: "Collation %@ is not valid for character set %@"),
                        collation,
                        charset
                    ),
                    sqlState: nil
                )
            }
        }

        let escapedName = request.name.replacingOccurrences(of: "`", with: "``")
        var query = "CREATE DATABASE `\(escapedName)` CHARACTER SET \(charset)"
        if let collation = collationValue {
            query += " COLLATE \(collation)"
        }

        _ = try await execute(query: query)
    }
}

private extension MySQLPluginDriver {
    struct CharsetDefault {
        let charset: String
        let defaultCollation: String
    }

    struct CollationEntry {
        let collation: String
        let charset: String
    }

    struct ServerCharsetDefaults {
        let charset: String?
        let collation: String?
    }

    func fetchCharsetDefaults() async throws -> [CharsetDefault] {
        let query = """
            SELECT character_set_name, default_collate_name
            FROM information_schema.character_sets
            ORDER BY character_set_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let charset = row[safe: 0] ?? nil,
                  let collation = row[safe: 1] ?? nil else {
                return nil
            }
            return CharsetDefault(charset: charset, defaultCollation: collation)
        }
    }

    func fetchCollationCatalog() async throws -> [CollationEntry] {
        let query = """
            SELECT collation_name, character_set_name
            FROM information_schema.collations
            ORDER BY collation_name
            """
        let result = try await execute(query: query)
        return result.rows.compactMap { row in
            guard let collation = row[safe: 0] ?? nil,
                  let charset = row[safe: 1] ?? nil else {
                return nil
            }
            return CollationEntry(collation: collation, charset: charset)
        }
    }

    enum SessionVariable: String {
        case characterSetDatabase = "character_set_database"
        case collationDatabase = "collation_database"
    }

    func fetchServerCharsetDefaults() async -> ServerCharsetDefaults {
        let charset = await fetchSessionVariable(.characterSetDatabase)
        let collation = await fetchSessionVariable(.collationDatabase)
        return ServerCharsetDefaults(charset: charset, collation: collation)
    }

    func fetchSessionVariable(_ variable: SessionVariable) async -> String? {
        do {
            let result = try await execute(query: "SHOW VARIABLES LIKE '\(variable.rawValue)'")
            guard let row = result.rows.first, let value = row[safe: 1] ?? nil else {
                return nil
            }
            return value
        } catch {
            Self.logger.warning(
                "Failed to read session variable \(variable.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    func isSafeCharsetIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
