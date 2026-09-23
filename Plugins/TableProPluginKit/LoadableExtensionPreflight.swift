import Foundation
#if os(macOS)
import Security
#endif

/// The checks an extension list passes before SQLite is asked to load any of it.
///
/// SQLite's own message for a file it cannot open names a path it retried with ".dylib" appended,
/// so a typo reads as "tried: 'x.dylib.dylib' (no such file)". These checks answer the common cases
/// in the user's terms first, and refuse the one case dyld cannot answer at all: a signed library
/// modified after signing, which macOS kills the process for rather than failing the load.
public enum LoadableExtensionPreflight {
    public static let maximumPathLength = 1_024

    public static func validate(_ extensions: [LoadableExtension]) throws {
        var seen = Set<LoadableExtension>()
        for item in extensions {
            guard !item.path.isEmpty else { throw LoadableExtensionError.missingPath }
            guard !containsLineBreakOrControl(item.path) else {
                throw LoadableExtensionError.controlCharacterInPath
            }
            guard item.expandedPath.hasPrefix("/") else { throw LoadableExtensionError.relativePath(item) }
            guard item.expandedPath.utf8.count <= maximumPathLength else {
                throw LoadableExtensionError.pathTooLong(item)
            }
            if let entryPoint = item.entryPoint, !isCIdentifier(entryPoint) {
                throw LoadableExtensionError.invalidEntryPoint(item)
            }
            let canonical = LoadableExtension(path: item.expandedPath, entryPoint: item.entryPoint)
            guard seen.insert(canonical).inserted else { throw LoadableExtensionError.duplicate(item) }
        }
    }

    /// The file SQLite should be handed. SQLite retries a path with ".dylib" appended, so
    /// `/opt/homebrew/lib/mod_spatialite` names `mod_spatialite.dylib`; the same rule applies here,
    /// and the resolved file is what gets passed on so the two never disagree.
    public static func resolveFile(for item: LoadableExtension, fileManager: FileManager = .default) throws -> String {
        for file in [item.expandedPath, item.expandedPath + ".dylib"] {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: file, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue else { throw LoadableExtensionError.notAFile(item) }
            guard !hasDamagedSignature(file) else { throw LoadableExtensionError.damagedSignature(item) }
            return file
        }
        throw LoadableExtensionError.fileNotFound(item)
    }

    /// `.controlCharacters` leaves out U+2028 and U+2029, which an alert renders as line breaks.
    public static func containsLineBreakOrControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    /// The same file under two spellings, `/x/foo` beside `/x/foo.dylib` or a Homebrew symlink beside
    /// its Cellar target, loads once: a second load of one library runs its initializer again.
    public static func loadedFileKey(for file: String, entryPoint: String?) -> String {
        (file as NSString).resolvingSymlinksInPath + "\u{0}" + (entryPoint ?? "")
    }

    public static func isCIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// Only a signature that is present and does not match the code is refused. An unsigned file is
    /// left to dyld, which rejects it on Apple silicon with its own message and loads it on Intel.
    public static func hasDamagedSignature(_ path: String) -> Bool {
        #if os(macOS)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, [], nil) == errSecCSSignatureFailed
        #else
        return false
        #endif
    }
}
