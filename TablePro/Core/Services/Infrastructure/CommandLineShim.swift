//
//  CommandLineShim.swift
//  TablePro
//

import Foundation

internal enum CommandLineShimStatus: Equatable, Sendable {
    case linked
    case notLinked
    case otherFile
}

/// The `tablepro` shim ships in the bundle and the person links it onto their PATH with a command
/// they run themselves, so the app never writes outside its own container or asks for admin rights.
internal struct CommandLineShim: Sendable {
    internal static let linkPath = "/usr/local/bin/tablepro"

    internal let shimPath: String
    internal let linkPath: String

    internal init(bundle: Bundle = .main, linkPath: String = CommandLineShim.linkPath) {
        let sharedSupport = bundle.sharedSupportURL ?? bundle.bundleURL.appendingPathComponent("Contents/SharedSupport")
        self.init(shimPath: sharedSupport.appendingPathComponent("bin/tablepro").path, linkPath: linkPath)
    }

    internal init(shimPath: String, linkPath: String) {
        self.shimPath = shimPath
        self.linkPath = linkPath
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

    /// `rm -f` first: `ln -sf` onto a link to a directory writes inside that directory, and `rm`
    /// refuses a real directory, so the line stops instead of touching one.
    internal var linkCommand: String {
        let directory = (linkPath as NSString).deletingLastPathComponent
        let link = Self.quote(linkPath)
        return "sudo mkdir -p \(Self.quote(directory)) && sudo rm -f \(link) && sudo ln -s \(Self.quote(shimPath)) \(link)"
    }

    internal var unlinkCommand: String {
        "sudo rm \(Self.quote(linkPath))"
    }

    internal static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
