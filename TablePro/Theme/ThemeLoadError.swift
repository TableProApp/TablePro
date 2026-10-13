import Foundation

internal enum ThemeLoadError: LocalizedError, Equatable {
    case missingSchema
    case schemaTooOld(found: Int, supported: Int)
    case schemaTooNew(found: Int, supported: Int)
    case missingField(String)
    case invalidColor(String)
    case unknownKeys([String])
    case duplicateKey(String)
    case reservedIdentifier(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String, existingFile: String)
    case changedOnDisk(String)

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
        case let .invalidColor(value):
            return String(format: String(localized: "\"%@\" is not a valid color. Use #RRGGBB or #RRGGBBAA."), value)
        case let .unknownKeys(names):
            let shown = ListFormatter.localizedString(byJoining: names.prefix(3).map { "\"\($0)\"" })
            return String(format: String(localized: "TablePro does not use these theme keys: %@."), shown)
        case let .duplicateKey(path):
            return String(format: String(localized: "The theme sets \"%@\" more than once."), path)
        case let .reservedIdentifier(identifier):
            return String(format: String(localized: "\"%@\" is a reserved theme identifier."), identifier)
        case let .invalidIdentifier(identifier):
            return String(format: String(localized: "\"%@\" is not a valid theme identifier."), identifier)
        case let .changedOnDisk(fileName):
            return String(
                format: String(localized: "%@ changed on disk since it was opened. The newer file was kept and reloaded."),
                fileName
            )
        case let .duplicateIdentifier(identifier, existingFile):
            return String(
                format: String(localized: "The theme identifier \"%1$@\" is already used by %2$@."),
                identifier,
                existingFile
            )
        }
    }
}
