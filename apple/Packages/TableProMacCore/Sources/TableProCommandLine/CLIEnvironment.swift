import Darwin
import Foundation
import TableProMCP

public protocol CLIConsole: AnyObject, Sendable {
    func out(_ text: String)
    func err(_ text: String)
}

public struct CLITerminal: Sendable, Equatable {
    public let standardInput: Bool
    public let standardOutput: Bool
    public let standardError: Bool

    public init(standardInput: Bool, standardOutput: Bool, standardError: Bool) {
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public static var current: CLITerminal {
        CLITerminal(
            standardInput: isatty(STDIN_FILENO) == 1,
            standardOutput: isatty(STDOUT_FILENO) == 1,
            standardError: isatty(STDERR_FILENO) == 1
        )
    }
}

// `appPath` is the bundle of the process serving MCP, which a pairing link has to reach.
public struct CLIServerEndpoint: Sendable, Equatable {
    public let socketPath: String
    public let appPath: String?

    public init(socketPath: String, appPath: String?) {
        self.socketPath = socketPath
        self.appPath = appPath
    }
}

// What `status` and `unpair` see without launching TablePro or waiting for it.
public enum CLIServerProbe: Sendable, Equatable {
    case reachable(CLIServerEndpoint)
    case notRunning
    case turnedOff
    case unreachable(String)
}

public struct CLIHostApp: Sendable, Equatable {
    public let url: URL?
    public let version: String?
    public let bundleIdentifier: String?

    public init(url: URL?, version: String?, bundleIdentifier: String?) {
        self.url = url
        self.version = version
        self.bundleIdentifier = bundleIdentifier
    }

    public init(executablePath: String?) {
        guard let url = executablePath.flatMap(MCPHostApp.containing(executablePath:)) else {
            self.init(url: nil, version: nil, bundleIdentifier: nil)
            return
        }
        let bundle = Bundle(url: url)
        self.init(
            url: url,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            bundleIdentifier: bundle?.bundleIdentifier
        )
    }

    public static let current = CLIHostApp(executablePath: MCPHandshakeTrust.executablePath(forPid: getpid()))

    var versionLine: String {
        "tablepro \(version ?? "unknown")"
    }
}

public struct CLIEnvironment: Sendable {
    public typealias ServerOpener = @Sendable () async throws -> CLIServerEndpoint
    public typealias ServerFinder = @Sendable () async -> CLIServerProbe
    public typealias Pairer = @Sendable (_ server: CLIServerEndpoint) async throws -> String
    public typealias TargetOpener = @Sendable (_ targets: [URL]) async throws -> Void
    public typealias TextReader = @Sendable () throws -> String
    public typealias FileReader = @Sendable (_ path: String) throws -> String
    public typealias FileCheck = @Sendable (_ path: String) -> Bool

    public var console: any CLIConsole
    public var terminal: CLITerminal
    public var tokenStore: any CLITokenStoring
    public var app: CLIHostApp
    // Launches TablePro when it is not running, then proves the server before any token goes out.
    public var openServer: ServerOpener
    public var findServer: ServerFinder
    public var pair: Pairer
    public var openTargets: TargetOpener
    public var readStandardInput: TextReader
    public var readFile: FileReader
    public var fileExists: FileCheck
    public var currentDirectory: URL

    public init(
        console: any CLIConsole,
        terminal: CLITerminal,
        tokenStore: any CLITokenStoring,
        app: CLIHostApp,
        openServer: @escaping ServerOpener,
        findServer: @escaping ServerFinder,
        pair: @escaping Pairer,
        openTargets: @escaping TargetOpener,
        readStandardInput: @escaping TextReader,
        readFile: @escaping FileReader,
        fileExists: @escaping FileCheck,
        currentDirectory: URL
    ) {
        self.console = console
        self.terminal = terminal
        self.tokenStore = tokenStore
        self.app = app
        self.openServer = openServer
        self.findServer = findServer
        self.pair = pair
        self.openTargets = openTargets
        self.readStandardInput = readStandardInput
        self.readFile = readFile
        self.fileExists = fileExists
        self.currentDirectory = currentDirectory
    }
}
