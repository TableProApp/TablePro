import Foundation

nonisolated enum MSSQLLoginField: Equatable {
    case user
    case password
    case application
    case nationalLanguage
    case charset
    case database
}

nonisolated struct MSSQLLoginParameter: Equatable {
    let field: MSSQLLoginField
    let value: String
}

nonisolated enum MSSQLLoginParameters {
    static let nationalLanguage = "us_english"
    static let charset = "UTF-8"

    static func build(
        user: String,
        password: String,
        applicationName: String,
        database: String
    ) -> [MSSQLLoginParameter] {
        var parameters = [
            MSSQLLoginParameter(field: .user, value: user),
            MSSQLLoginParameter(field: .password, value: password),
            MSSQLLoginParameter(field: .application, value: applicationName),
            MSSQLLoginParameter(field: .nationalLanguage, value: nationalLanguage),
            MSSQLLoginParameter(field: .charset, value: charset)
        ]
        if !database.isEmpty {
            parameters.append(MSSQLLoginParameter(field: .database, value: database))
        }
        return parameters
    }
}
