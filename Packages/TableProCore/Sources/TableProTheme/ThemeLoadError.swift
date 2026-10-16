import Foundation

public enum ThemeLoadError: LocalizedError, Equatable, Sendable {
    case malformedJSON(detail: String?)
    case missingSchema
    case schemaTooOld(found: Int, supported: Int)
    case schemaTooNew(found: Int, supported: Int)
    case missingField(String)
    case invalidName
    case invalidAuthor
    case invalidColor(String)
    case unknownKeys([String])
    case duplicateKey(String)
    case reservedIdentifier(String)
    case invalidIdentifier(String)
    case duplicateIdentifier(String, existingFile: String)
    case changedOnDisk(String)
    case deletedOnDisk(String)
    case nameTaken(String)
    case fileTooLarge(limit: Int)
    case notATheme
    case includeOutsideFolder(String)
    case includeMissing(String)
    case includeCycle(String)
    case includeTooDeep(limit: Int)
    case invalidColorMap
    case invalidTokenColors
    case invalidTextMateTheme(String)
    case tooManyTokenRules(limit: Int)
    case tokenScopeTooLong(limit: Int)
    case tokenScopeHasTooManyParts(limit: Int)
    case nestingTooDeep(limit: Int)
    case noUsableColors

    public var errorDescription: String? {
        switch self {
        case let .malformedJSON(detail):
            let message = String(localized: "The file is not valid JSON.")
            guard let detail, !detail.isEmpty else { return message }
            return message + "\n" + detail
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
        case .invalidName:
            return String(
                format: String(localized: "A theme name must be one line of at most %d characters."),
                ThemeFileFormat.maximumTextLength
            )
        case .invalidAuthor:
            return String(
                format: String(localized: "A theme author must be one line of at most %d characters."),
                ThemeFileFormat.maximumTextLength
            )
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
        case let .duplicateIdentifier(identifier, existingFile):
            return String(
                format: String(localized: "The theme identifier \"%1$@\" is already used by %2$@."),
                identifier,
                existingFile
            )
        case let .changedOnDisk(fileName):
            return String(
                format: String(localized: "%@ changed on disk since it was opened. The newer file was kept and reloaded."),
                fileName
            )
        case let .deletedOnDisk(fileName):
            return String(format: String(localized: "%@ was deleted outside TablePro."), fileName)
        case let .nameTaken(name):
            return String(format: String(localized: "A theme named “%@” already exists."), name)
        case let .fileTooLarge(limit):
            let size = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .memory)
            return String(format: String(localized: "The file is too large. A theme file can be at most %@."), size)
        case .notATheme:
            return String(localized: "This file is not a TablePro theme or a VS Code color theme.")
        case let .includeOutsideFolder(path):
            return String(
                format: String(
                    localized: "The theme includes \"%@\", which is outside its folder. Put that file next to the theme and import again."
                ),
                path
            )
        case let .includeMissing(path):
            return String(format: String(localized: "The theme includes \"%@\", which is not next to it."), path)
        case let .includeCycle(path):
            return String(format: String(localized: "The theme includes itself through \"%@\"."), path)
        case let .includeTooDeep(limit):
            return String(format: String(localized: "The theme nests includes more than %d levels deep."), limit)
        case .invalidColorMap:
            return String(localized: "\"colors\" in the theme is not a list of colors.")
        case .invalidTokenColors:
            return String(localized: "\"tokenColors\" must be a list of rules or the path to a .tmTheme file.")
        case let .invalidTextMateTheme(fileName):
            return String(format: String(localized: "\"%@\" is not a TextMate theme."), fileName)
        case let .tooManyTokenRules(limit):
            return String(format: String(localized: "The theme has more than %@ token color rules."), limit.formatted())
        case let .tokenScopeTooLong(limit):
            return String(format: String(localized: "A token color scope in the theme is longer than %@ characters."), limit.formatted())
        case let .tokenScopeHasTooManyParts(limit):
            return String(format: String(localized: "A token color scope in the theme has more than %d dot-separated parts."), limit)
        case let .nestingTooDeep(limit):
            return String(format: String(localized: "The file nests arrays and objects more than %d levels deep."), limit)
        case .noUsableColors:
            return String(localized: "The theme has no colors TablePro can use.")
        }
    }
}
