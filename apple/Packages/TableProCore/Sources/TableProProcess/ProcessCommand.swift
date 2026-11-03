import Foundation

public struct ProcessCommand: Sendable, Equatable {
    public enum UserShell: Sendable, Equatable {
        case sh
        case bash

        var executable: URL {
            switch self {
            case .sh: URL(fileURLWithPath: "/bin/sh")
            case .bash: URL(fileURLWithPath: "/bin/bash")
            }
        }
    }

    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL
    let isUserAuthored: Bool
    // Shell text written here, in this package, with every value passed as a positional parameter.
    let isFixedScript: Bool

    // An app-authored launch, which may not name a shell by its path.
    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) {
        self.init(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            isUserAuthored: false
        )
    }

    private init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        isUserAuthored: Bool,
        isFixedScript: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        // `/` holds nothing a user can plant, unlike the folder the app happened to start in.
        self.currentDirectory = currentDirectory ?? URL(fileURLWithPath: "/", isDirectory: true)
        self.isUserAuthored = isUserAuthored
        self.isFixedScript = isFixedScript
    }

    static let reopenScript = #"while /bin/kill -0 "$0" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$1""#

    // Opens `application` once the process `pid` has exited, for a relaunch. The wait has to outlive the
    // app that asks for it, and only a shell loop waits on a process that is not its child. The script is
    // fixed text; the pid and the path reach it as `$0` and `$1`, never as part of it.
    public static func reopen(_ application: URL, afterExitOf pid: Int32) -> ProcessCommand {
        ProcessCommand(
            executable: UserShell.sh.executable,
            arguments: ["-c", reopenScript, String(pid), application.path],
            environment: [:],
            currentDirectory: nil,
            isUserAuthored: false,
            isFixedScript: true
        )
    }

    // An argument list the user wrote, such as a custom tunnel command, which may name a shell.
    public static func userAuthored(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL? = nil
    ) -> ProcessCommand {
        ProcessCommand(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            isUserAuthored: true
        )
    }

    // Shell text the user wrote. Other values go in `environment`, except the checked names Match exec
    // substitutes, as OpenSSH does.
    public static func userShell(
        _ script: String,
        shell: UserShell,
        environment: [String: String],
        currentDirectory: URL? = nil
    ) -> ProcessCommand {
        userAuthored(
            executable: shell.executable,
            arguments: ["-c", script],
            environment: environment,
            currentDirectory: currentDirectory
        )
    }
}
