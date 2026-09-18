import Foundation

public enum SpannerSchemaName {
    public static let defaultToken = "(default)"

    public static func sqlName(_ presented: String?, dialect: SpannerDialect) -> String {
        guard let presented, !presented.isEmpty, presented != defaultToken else { return dialect.defaultSchema }
        return presented
    }

    public static func presentedName(_ sqlName: String, dialect: SpannerDialect) -> String {
        switch dialect {
        case .googleSQL:
            sqlName.isEmpty ? defaultToken : sqlName
        case .postgreSQL:
            sqlName
        }
    }
}
