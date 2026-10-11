import Foundation

internal enum ThemeLoadError: LocalizedError, Equatable {
    case missingSchema
    case schemaTooOld(found: Int, supported: Int)
    case schemaTooNew(found: Int, supported: Int)
    case missingField(String)
    case missingSlots([String])
    case invalidColor(String)
    case unknownSystemColor(String)
    case unknownKeys([String])
    case reservedIdentifier(String)
    case invalidIdentifier(String)

    internal var errorDescription: String? {
        switch self {
        case .missingSchema:
            return String(localized: "The file does not declare a theme format version.")
        case let .schemaTooOld(found, supported):
            return String(
                format: String(localized: "Theme format %1$d is no longer supported. This version of TablePro reads format %2$d."),
                found,
                supported
            )
        case let .schemaTooNew(found, supported):
            return String(
                format: String(localized: "Theme format %1$d was made for a newer TablePro. This version reads format %2$d."),
                found,
                supported
            )
        case let .missingField(name):
            return String(format: String(localized: "The theme is missing the required field \"%@\"."), name)
        case let .missingSlots(names):
            return String(
                format: String(localized: "The theme is missing %1$d required colors, starting with \"%2$@\"."),
                names.count,
                names.first ?? ""
            )
        case let .invalidColor(value):
            return String(format: String(localized: "\"%@\" is not a valid color."), value)
        case let .unknownSystemColor(name):
            return String(format: String(localized: "\"%@\" is not a system color TablePro knows."), name)
        case let .unknownKeys(names):
            return String(
                format: String(localized: "The theme declares %1$d colors TablePro does not use, starting with \"%2$@\"."),
                names.count,
                names.first ?? ""
            )
        case let .reservedIdentifier(identifier):
            return String(format: String(localized: "\"%@\" is a reserved theme identifier."), identifier)
        case let .invalidIdentifier(identifier):
            return String(format: String(localized: "\"%@\" is not a valid theme identifier."), identifier)
        }
    }
}
