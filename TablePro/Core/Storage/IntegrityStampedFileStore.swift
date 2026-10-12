//
//  IntegrityStampedFileStore.swift
//  TablePro
//

import Foundation
import os

/// A `Codable` list in a file that can say whether TablePro is the last thing that wrote it.
///
/// `connections.json` needs that answer because a connection can declare a `PasswordSource` whose
/// shell command the app runs at connect time, and the file is ordinary user-writable storage. A
/// credential profile can declare the same thing, so it needs the same answer rather than a second
/// hand-written copy of the read-verify-adopt and write-stamp cycle.
///
/// The load is deliberately three-valued. A file that will not decode is not an empty list: saving
/// over it would destroy whatever it held, which is why every caller has to tell the two apart.
@MainActor
final class IntegrityStampedFileStore<Element: Codable> {
    /// Whether the file on disk is the one TablePro last wrote. False once something else has
    /// edited it, which is the signal to refuse to run anything it declares.
    ///
    /// False until a load has answered. Starting at true meant a caller that read the flag before
    /// reading the file got "trusted" for a file nothing had verified.
    private(set) var isTrusted = false

    let fileURL: URL

    private let label: String
    private let logger: Logger
    private let integrity: ConnectionStoreIntegrity
    private let userSaveEstablishesTrust: Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// `userSaveEstablishesTrust` says whether writing this file is itself the user's consent to
    /// trust what is in it.
    ///
    /// `connections.json` says yes, and that is deliberate: it predates the tag, so an untagged one
    /// is an ordinary upgrade, and re-saving a connection in the app is the documented way to clear
    /// a tamper flag. `credentialProfiles.json` says no. It has no untagged history, and its writes
    /// are read-modify-write over the whole list, so saving any profile would re-sign every other
    /// entry in the file. That is how a planted `.command(shell:)` would get blessed by a user who
    /// only renamed something.
    init(
        fileURL: URL,
        label: String,
        logger: Logger,
        userSaveEstablishesTrust: Bool,
        integrity: ConnectionStoreIntegrity = .shared
    ) {
        self.fileURL = fileURL
        self.label = label
        self.logger = logger
        self.userSaveEstablishesTrust = userSaveEstablishesTrust
        self.integrity = integrity
    }

    /// Nil when the file exists and could not be decoded. An absent file is an empty list, which is
    /// a fresh install rather than a failure.
    func load() -> [Element]? {
        guard let data = try? Data(contentsOf: fileURL) else {
            isTrusted = true
            return []
        }

        switch integrity.verify(data, fileURL: fileURL) {
        case .trusted:
            isTrusted = true
        case .unstamped:
            guard userSaveEstablishesTrust else {
                logger.warning("\(self.label, privacy: .public) has no integrity tag; anything it declares will not run")
                isTrusted = false
                break
            }
            /// An install that predates the tag. Adopt the file as it stands, which is the only
            /// option without a prior baseline, and stamp it so later edits are detectable.
            integrity.stamp(data, fileURL: fileURL)
            isTrusted = true
        case .modified:
            logger.warning("\(self.label, privacy: .public) changed outside TablePro; anything it declares will not run")
            isTrusted = false
        case .unavailable:
            logger.warning("No integrity key for \(self.label, privacy: .public); anything it declares will not run")
            isTrusted = false
        }

        do {
            return try decoder.decode([Element].self, from: data)
        } catch {
            logger.error("Failed to decode \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    /// False when nothing reached disk. A caller that also writes keychain items or sync tombstones
    /// has to abort on that rather than strand them against a record that was never persisted.
    @discardableResult
    func save(_ elements: [Element]) -> Bool {
        do {
            let data = try encoder.encode(elements)
            try data.write(to: fileURL, options: .atomic)
            /// A store that does not take a save as consent keeps the verdict its last load
            /// reached: the write lands, so the user's edit is not lost, but nothing in the file
            /// becomes trusted because of it.
            guard userSaveEstablishesTrust || isTrusted else {
                logger.warning("Saved \(self.label, privacy: .public) without a trust tag; it stays untrusted")
                return true
            }
            /// Trust follows the tag. If no tag could be written, later edits are undetectable, so
            /// the file is not treated as trusted.
            isTrusted = integrity.stamp(data, fileURL: fileURL)
            return true
        } catch {
            logger.error("Failed to save \(self.label, privacy: .public): \(error.publicLogShape, privacy: .public)")
            return false
        }
    }
}
