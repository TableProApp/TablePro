import Foundation

/// Reads a theme file someone picked or dropped: a TablePro theme or a VS Code color theme. The file
/// is untrusted, so its size is checked before a byte is read, and every import mints a new id: the
/// id in a file says nothing about which theme on this Mac it is.
public enum ThemeFileImporter {
    public static let maximumFileSize = 2 * 1_024 * 1_024

    private static let vsCodeSchema = "vscode://schemas/color-theme"
    private static let vsCodeKeys = ["colors", "tokenColors", "include", "settings"]

    private enum Format {
        case tablePro
        case vsCode([String: VSCodeThemeValue])
    }

    public static func importTheme(at url: URL) throws -> ThemeDefinition {
        let data = try contents(of: url)
        let id = ThemeIdentifier.generated()
        switch try detectFormat(of: data) {
        case .tablePro:
            var theme = try ThemeFileFormat.decode(data)
            theme.id = id
            return theme
        case let .vsCode(root):
            return try VSCodeThemeImporter(fileURL: url).makeTheme(from: root, id: id)
        }
    }

    // JSON5 reads both formats, so its error points at the real fault in either. A TablePro theme then
    // goes through the strict decoder, which refuses the comments VS Code allows.
    private static func detectFormat(of data: Data) throws -> Format {
        let root: VSCodeThemeValue
        do {
            root = try VSCodeThemeValue.parse(data)
        } catch {
            // A file that starts like neither a JSON object nor a comment is not a theme in any format.
            guard let first = firstSignificantByte(of: data), first == UInt8(ascii: "{") || first == UInt8(ascii: "/") else {
                throw ThemeLoadError.notATheme
            }
            throw error
        }

        guard let object = root.objectValue else { throw ThemeLoadError.notATheme }
        if case .number = object["schema"] {
            return .tablePro
        }
        if object["$schema"]?.stringValue == vsCodeSchema || vsCodeKeys.contains(where: { object[$0] != nil }) {
            return .vsCode(object)
        }
        // A TablePro file with a malformed or legacy version keeps the decoder's error about it.
        if object["schema"] != nil || object["version"] != nil {
            return .tablePro
        }
        throw ThemeLoadError.notATheme
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    private static func firstSignificantByte(of data: Data) -> UInt8? {
        let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data[...]
        return body.first { !whitespace.contains($0) }
    }

    // Also reads every file a VS Code theme includes, each under the same cap.
    internal static func contents(of url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumFileSize else { throw ThemeLoadError.fileTooLarge(limit: maximumFileSize) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // The file can grow between the size check and the read.
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else { throw ThemeLoadError.fileTooLarge(limit: maximumFileSize) }
        return data
    }
}
