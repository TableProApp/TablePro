import Foundation

public enum ProcessLaunchError: Error, Equatable, Sendable, LocalizedError {
    case executableNotAbsolute(String)
    case shellNotAllowed(String)
    case nulCharacter
    case invalidEnvironmentName(String)
    case rewrittenOnLaunch(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotAbsolute(let path):
            return String(format: String(localized: "TablePro runs a tool only by its full path, not %@."), path)
        case .shellNotAllowed(let path):
            return String(format: String(localized: "TablePro does not pass values through the shell %@."), path)
        case .nulCharacter:
            return String(localized: "A value holds a NUL character, which a command line cannot carry.")
        case .invalidEnvironmentName(let name):
            return String(format: String(localized: "%@ is not a valid environment variable name."), name)
        case .rewrittenOnLaunch(let value):
            return String(
                format: String(localized: "%@ holds a character macOS would turn into command line punctuation."),
                value
            )
        }
    }
}

#if !canImport(Darwin)
// Foundation on Linux has no String(localized:).
private extension String {
    init(localized text: String) {
        self = text
    }
}
#endif

public enum ProcessLauncher {
    static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env"]

    // The only place production code makes a `Process`. It comes back configured and not yet running,
    // so each caller keeps its own pipes, timeout and termination handling.
    public static func process(for command: ProcessCommand) throws -> Process {
        try validate(command)
        let process = Process()
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.environment = command.environment
        process.currentDirectoryURL = command.currentDirectory
        process.standardInput = FileHandle.nullDevice
        return process
    }

    static func validate(_ command: ProcessCommand) throws {
        // A non-file URL makes Process raise an exception that ends the app, and a relative one resolves
        // against the app's current folder.
        let executable = command.executable
        guard executable.isFileURL, executable.baseURL == nil, executable.path.hasPrefix("/") else {
            throw ProcessLaunchError.executableNotAbsolute(command.executable.relativeString)
        }
        if !command.isUserAuthored, !command.isFixedScript, shellNames.contains(command.executable.lastPathComponent) {
            throw ProcessLaunchError.shellNotAllowed(command.executable.path)
        }
        for argument in command.arguments {
            try refuseNUL(argument)
            // A shell reads what Process hands over, so in its text U+037E is `;` and U+1FEF a backtick.
            if command.isUserAuthored { try refusePunctuationRewrite(argument) }
        }
        for (name, value) in command.environment {
            guard !name.isEmpty, !name.unicodeScalars.contains("=") else {
                throw ProcessLaunchError.invalidEnvironmentName(name)
            }
            try refuseNUL(name)
            try refuseNUL(value)
        }
    }

    // Process raises an exception that ends the app on a NUL in any argument or variable.
    private static func refuseNUL(_ value: String) throws {
        guard !value.unicodeScalars.contains("\0") else { throw ProcessLaunchError.nulCharacter }
    }

    // Process hands every argument over in its decomposed file system form. A value whose ASCII
    // punctuation changes on the way is refused, so a check made on the Swift string still holds.
    static func refusePunctuationRewrite(_ value: String) throws {
        guard value.utf8.contains(where: { $0 >= 0x80 }) else { return }
        guard let launched = launchedBytes(of: value),
              punctuation(in: launched) == punctuation(in: Array(value.utf8)) else {
            throw ProcessLaunchError.rewrittenOnLaunch(value)
        }
    }

    // The bytes Process gives the child. NSString.fileSystemRepresentation is not the same: it drops a
    // leading U+FEFF and raises on what is left empty.
    static func launchedBytes(of value: String) -> [UInt8]? {
        #if canImport(Darwin)
        let text = value as CFString
        let capacity = CFStringGetMaximumSizeOfFileSystemRepresentation(text)
        var buffer = [CChar](repeating: 0, count: capacity)
        guard CFStringGetFileSystemRepresentation(text, &buffer, capacity) else { return nil }
        return buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        #else
        return Array(value.utf8)
        #endif
    }

    private static func punctuation(in bytes: [UInt8]) -> [UInt8] {
        bytes.filter { byte in
            byte < 0x80 && !(0x30...0x39).contains(byte) && !(0x41...0x5A).contains(byte) && !(0x61...0x7A).contains(byte)
        }
    }
}
