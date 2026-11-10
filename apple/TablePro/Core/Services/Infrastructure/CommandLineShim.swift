import Foundation
import TableProProcess

internal enum CommandLineShimStatus: Equatable, Sendable {
    case linked
    case notLinked
    case otherFile
}

// The person runs the link line themselves, so the app never writes outside its bundle or asks for admin rights.
internal struct CommandLineShim: Sendable {
    internal static let linkPath = "/usr/local/bin/tablepro"

    internal let shimPath: String
    internal let linkPath: String
    private let readOnlyVolumeCheck: @Sendable (URL) -> Bool

    internal init(
        bundle: Bundle = .main,
        linkPath: String = CommandLineShim.linkPath,
        isOnReadOnlyVolume: @escaping @Sendable (URL) -> Bool = { CommandLineShim.isOnReadOnlyVolume($0) }
    ) {
        let sharedSupport = bundle.sharedSupportURL ?? bundle.bundleURL.appendingPathComponent("Contents/SharedSupport")
        self.init(
            shimPath: sharedSupport.appendingPathComponent("bin/tablepro").path,
            linkPath: linkPath,
            isOnReadOnlyVolume: isOnReadOnlyVolume
        )
    }

    internal init(
        shimPath: String,
        linkPath: String,
        isOnReadOnlyVolume: @escaping @Sendable (URL) -> Bool = { CommandLineShim.isOnReadOnlyVolume($0) }
    ) {
        self.shimPath = shimPath
        self.linkPath = linkPath
        self.readOnlyVolumeCheck = isOnReadOnlyVolume
    }

    internal func status(fileManager: FileManager = .default) -> CommandLineShimStatus {
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
            let resolved = URL(fileURLWithPath: destination, relativeTo: URL(fileURLWithPath: linkPath))
            return resolved.standardizedFileURL.path == URL(fileURLWithPath: shimPath).standardizedFileURL.path
                ? .linked
                : .otherFile
        }
        return fileManager.fileExists(atPath: linkPath) ? .otherFile : .notLinked
    }

    // A disk image or a translocated copy is read-only and gone after eject or relaunch, so a link to it dangles.
    internal func command(for status: CommandLineShimStatus) -> String? {
        switch status {
        case .linked:
            unlinkCommand
        case .notLinked, .otherFile:
            readOnlyVolumeCheck(URL(fileURLWithPath: shimPath)) ? nil : linkCommand
        }
    }

    // rm -f first: ln -sf onto a link to a directory writes inside it, and rm refuses a real directory.
    internal var linkCommand: String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        let link = Self.quote(linkPath)
        return "sudo mkdir -p \(Self.quote(directory)) && sudo rm -f \(link) && sudo ln -s \(Self.quote(shimPath)) \(link)"
    }

    internal var unlinkCommand: String {
        "sudo rm \(Self.quote(linkPath))"
    }

    // A path holds no NUL. Were one there, the reader sees it escaped instead of a line the shell cuts short.
    internal static func quote(_ value: String) -> String {
        (try? ShellQuoting.singleQuoted(value)) ?? ShellQuoting.displayWord(value)
    }

    internal static func isOnReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }
}
