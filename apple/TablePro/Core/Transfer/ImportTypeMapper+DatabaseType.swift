import Foundation
import TableProPluginKit

extension ImportTypeMapper {
    static func sqlType(
        for type: PluginImportFieldType,
        databaseType: DatabaseType,
        serverVersion: String? = nil
    ) -> String {
        sqlType(for: type, databaseTypeId: databaseType.rawValue, serverVersion: serverVersion)
    }
}

extension PostgreSQLServerVersion {
    static func jsonColumnType(for databaseType: DatabaseType, serverVersion: String?) -> JSONColumnType {
        ImportTypeMapper.postgresJSONColumnType(databaseTypeId: databaseType.rawValue, serverVersion: serverVersion)
    }
}
