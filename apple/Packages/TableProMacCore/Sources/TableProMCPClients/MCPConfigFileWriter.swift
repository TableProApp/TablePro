import Foundation

public struct MCPConfigWriteResult: Sendable, Equatable {
    public let backupURL: URL?
    public let created: Bool

    public init(backupURL: URL?, created: Bool) {
        self.backupURL = backupURL
        self.created = created
    }
}

public enum MCPConfigWriteError: Error, Sendable, Equatable {
    case changedDuringWrite
    case verificationFailed
    case io(String)
}

// FileManager is documented as safe across threads when it has no delegate, and this one never gets one.
public struct MCPConfigFileWriter: @unchecked Sendable {
    public static let backupSuffix = ".tablepro-backup"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // `Data.write(.atomic)` would turn a symlinked config into a regular file, so the link is resolved and its
    // target replaced; replaceItemAt keeps the target's mode and leaves the previous bytes beside it as the backup.
    public func update(_ url: URL, transform: (String?) throws -> String) throws -> MCPConfigWriteResult {
        let target = try resolvedTarget(url)
        var snapshot = try read(target)
        for _ in 0..<2 {
            let newData = Data(try transform(try snapshot.map(decoded)).utf8)
            if newData == snapshot {
                return MCPConfigWriteResult(backupURL: nil, created: false)
            }
            let latest = try read(target)
            guard latest == snapshot else {
                snapshot = latest
                continue
            }
            let result = snapshot == nil ? try create(newData, at: target) : try replace(target, with: newData)
            guard try read(target) == newData else { throw MCPConfigWriteError.verificationFailed }
            return result
        }
        throw MCPConfigWriteError.changedDuringWrite
    }

    private func resolvedTarget(_ url: URL) throws -> URL {
        var current = url.standardizedFileURL
        for _ in 0..<32 {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: current.path) else {
                return current
            }
            let next = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination)
                : current.deletingLastPathComponent().appendingPathComponent(destination)
            current = next.standardizedFileURL
        }
        throw MCPConfigWriteError.io("symlinkLoop")
    }

    private func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw Self.ioError(error)
        }
    }

    private func decoded(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw MCPConfigWriteError.io("notUTF8") }
        return text
    }

    private func replace(_ target: URL, with data: Data) throws -> MCPConfigWriteResult {
        let backupName = target.lastPathComponent + Self.backupSuffix
        do {
            let directory = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true
            )
            defer { try? fileManager.removeItem(at: directory) }
            let temporary = directory.appendingPathComponent(target.lastPathComponent)
            try data.write(to: temporary)
            _ = try fileManager.replaceItemAt(
                target, withItemAt: temporary, backupItemName: backupName, options: [.withoutDeletingBackupItem]
            )
        } catch {
            throw Self.ioError(error)
        }
        return MCPConfigWriteResult(backupURL: target.deletingLastPathComponent().appendingPathComponent(backupName), created: false)
    }

    // Client configs often hold env secrets, so a new one starts at 0600.
    private func create(_ data: Data, at target: URL) throws -> MCPConfigWriteResult {
        let parent = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            let directory = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: parent, create: true
            )
            defer { try? fileManager.removeItem(at: directory) }
            let temporary = directory.appendingPathComponent(target.lastPathComponent)
            guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw MCPConfigWriteError.io("createFailed")
            }
            try fileManager.moveItem(at: temporary, to: target)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw MCPConfigWriteError.changedDuringWrite
        } catch let error as MCPConfigWriteError {
            throw error
        } catch {
            throw Self.ioError(error)
        }
        return MCPConfigWriteResult(backupURL: nil, created: true)
    }

    private static func ioError(_ error: any Error) -> MCPConfigWriteError {
        let nsError = error as NSError
        return .io("\(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}
