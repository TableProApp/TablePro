//
//  TransferProgress.swift
//  TablePro
//

import Foundation

internal enum TransferJob: Equatable, Sendable {
    case export
    case dataImport
    case backup(databaseCount: Int)
    case restore
    case tableTransfer(wrapsEachTable: Bool)
    case objectCopy

    internal var title: String {
        switch self {
        case .export: return String(localized: "Exporting")
        case .dataImport: return String(localized: "Importing")
        case .backup: return String(localized: "Backing Up")
        case .restore: return String(localized: "Restoring")
        case .tableTransfer: return String(localized: "Transferring")
        case .objectCopy: return String(localized: "Copying")
        }
    }

    internal var stopPolicy: TransferStopPolicy {
        switch self {
        case .export:
            // Not every format can stop its final write, so nothing is promised about the file.
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Export?"),
                confirmButton: String(localized: "Stop Export"),
                consequence: String(localized: "Partial files may remain on disk.")
            )
        case .dataImport:
            // Whether a Stop rolls back depends on the engine, the table and the user's own transaction.
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Import?"),
                confirmButton: String(localized: "Stop Import"),
                consequence: String(localized: "Anything already imported may stay.")
            )
        case .backup(let databaseCount):
            guard databaseCount > 1 else {
                return TransferStopPolicy(
                    action: .cancel,
                    confirmationTitle: String(localized: "Cancel Backup?"),
                    confirmButton: String(localized: "Cancel Backup"),
                    consequence: String(localized: "The partial backup file is removed.")
                )
            }
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Backup?"),
                confirmButton: String(localized: "Stop Backup"),
                consequence: String(localized: "Backups already written stay. The partial file is removed.")
            )
        case .restore:
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Restore?"),
                confirmButton: String(localized: "Stop Restore"),
                consequence: String(localized: "The database may be left partly restored.")
            )
        case .tableTransfer(let wrapsEachTable):
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Transfer?"),
                confirmButton: String(localized: "Stop Transfer"),
                // The checkbox asks for a transaction; an engine without one cannot roll back, so nothing is promised.
                consequence: wrapsEachTable
                    ? String(localized: "Tables already transferred stay.")
                    : String(localized: "Rows already transferred stay.")
            )
        case .objectCopy:
            return TransferStopPolicy(
                action: .stop,
                confirmationTitle: String(localized: "Stop Copy?"),
                confirmButton: String(localized: "Stop Copy"),
                consequence: String(localized: "Objects already copied stay.")
            )
        }
    }
}

// Cancel for a job that leaves nothing behind, Stop for one that leaves what it already did.
internal struct TransferStopPolicy: Equatable, Sendable {
    internal enum Action: Equatable, Sendable {
        case cancel
        case stop
    }

    internal let action: Action
    internal let confirmationTitle: String
    internal let confirmButton: String
    internal let consequence: String

    internal var buttonTitle: String {
        switch action {
        case .cancel: return String(localized: "Cancel")
        case .stop: return String(localized: "Stop")
        }
    }

    internal var stoppingTitle: String {
        switch action {
        case .cancel: return String(localized: "Cancelling…")
        case .stop: return String(localized: "Stopping…")
        }
    }
}

internal enum TransferUnit: Equatable, Sendable {
    case rows
    case statements
    case bytes
    case objects
}

internal struct TransferProgress: Equatable, Sendable {
    internal struct Step: Equatable, Sendable {
        internal let index: Int
        internal let count: Int
    }

    internal var job: TransferJob
    internal var item: String?
    internal var step: Step?
    internal var completed: Int64
    internal var total: Int64?
    internal var unit: TransferUnit
    internal var isEstimate: Bool
    internal var note: String?
    internal var fileFraction: Double?
    internal var isStopping: Bool

    internal init(
        job: TransferJob,
        item: String? = nil,
        step: Step? = nil,
        completed: Int64 = 0,
        total: Int64? = nil,
        unit: TransferUnit,
        isEstimate: Bool = false,
        note: String? = nil,
        fileFraction: Double? = nil,
        isStopping: Bool = false
    ) {
        self.job = job
        self.item = item.flatMap { $0.isEmpty ? nil : $0 }
        self.step = step.flatMap { $0.count > 1 ? $0 : nil }
        self.completed = max(0, completed)
        self.total = total.flatMap { $0 > 0 ? $0 : nil }
        self.unit = unit
        self.isEstimate = isEstimate
        self.note = note.flatMap { $0.isEmpty ? nil : $0 }
        self.fileFraction = fileFraction
        self.isStopping = isStopping
    }

    internal var title: String { job.title }

    internal var stopPolicy: TransferStopPolicy { job.stopPolicy }

    // An estimate stops short of the end, so a bar never reads done while the job still runs. So does a file read to
    // its end: its last statements still run.
    internal var fraction: Double? {
        // A statement count cannot move while one COPY streams its rows, and the file's bytes read can.
        if let fileFraction { return min(0.99, max(0.0, fileFraction)) }
        guard let total else { return nil }
        let ceiling = isEstimate ? 0.95 : 1.0
        return min(ceiling, Double(completed) / Double(total))
    }

    internal var itemText: String {
        let name = item ?? String(localized: "Preparing…")
        guard let step else { return name }
        return String(
            format: String(localized: "%1$@ (%2$lld of %3$lld)"),
            name, Int64(step.index), Int64(step.count)
        )
    }

    internal var amountText: String? {
        guard total != nil || completed > 0 else { return nil }
        guard unit != .bytes else { return bytesText }
        let done = Self.counted(completed)
        guard let total else {
            return String(format: plainTemplate(count: completed), done)
        }
        let template = isEstimate ? aboutTemplate(total: total) : ofTemplate(total: total)
        return String(format: template, done, Self.counted(total))
    }

    // A byte estimate is the database's size, not the file's, so it is never quoted as a total.
    private var bytesText: String {
        let done = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        guard let total, !isEstimate else { return done }
        return String(
            format: String(localized: "%1$@ of %2$@"),
            done, ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        )
    }

    private static func counted(_ value: Int64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    private func plainTemplate(count: Int64) -> String {
        let one = count == 1
        switch unit {
        case .rows: return one ? String(localized: "%@ row") : String(localized: "%@ rows")
        case .statements: return one ? String(localized: "%@ statement") : String(localized: "%@ statements")
        case .objects, .bytes: return one ? String(localized: "%@ object") : String(localized: "%@ objects")
        }
    }

    private func ofTemplate(total: Int64) -> String {
        let one = total == 1
        switch unit {
        case .rows:
            return one ? String(localized: "%1$@ of %2$@ row") : String(localized: "%1$@ of %2$@ rows")
        case .statements:
            return one ? String(localized: "%1$@ of %2$@ statement") : String(localized: "%1$@ of %2$@ statements")
        case .objects, .bytes:
            return one ? String(localized: "%1$@ of %2$@ object") : String(localized: "%1$@ of %2$@ objects")
        }
    }

    private func aboutTemplate(total: Int64) -> String {
        let one = total == 1
        switch unit {
        case .rows:
            return one ? String(localized: "%1$@ of about %2$@ row") : String(localized: "%1$@ of about %2$@ rows")
        case .statements:
            return one
                ? String(localized: "%1$@ of about %2$@ statement")
                : String(localized: "%1$@ of about %2$@ statements")
        case .objects, .bytes:
            return one
                ? String(localized: "%1$@ of about %2$@ object")
                : String(localized: "%1$@ of about %2$@ objects")
        }
    }
}
