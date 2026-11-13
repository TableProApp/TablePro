//
//  TransferProgressTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct TransferProgressTests {
    // Grouped in the runner's locale, which is not always a comma.
    private func grouped(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    @Test("A known total gives a fraction and a grouped amount")
    func knownTotal() {
        let progress = TransferProgress(job: .export, item: "users", completed: 95_500, total: 175_787, unit: .rows)

        #expect(progress.fraction == 95_500.0 / 175_787.0)
        #expect(progress.amountText == "\(grouped(95_500)) of \(grouped(175_787)) rows")
    }

    @Test("No total leaves the bar indeterminate and the amount a plain count")
    func unknownTotal() {
        let progress = TransferProgress(job: .export, completed: 18_204, unit: .rows)

        #expect(progress.fraction == nil)
        #expect(progress.amountText == "\(grouped(18_204)) rows")
    }

    @Test("A zero total is no total, never a bar stuck at zero")
    func zeroTotalIsNoTotal() {
        let progress = TransferProgress(job: .export, completed: 0, total: 0, unit: .rows)

        #expect(progress.fraction == nil)
        #expect(progress.amountText == nil)
    }

    @Test("An estimate stops the bar short of the end and says about")
    func estimate() {
        let progress = TransferProgress(
            job: .dataImport, completed: 5_000, total: 4_000, unit: .statements, isEstimate: true
        )

        #expect(progress.fraction == 0.95)
        #expect(progress.amountText == "\(grouped(5_000)) of about \(grouped(4_000)) statements")
    }

    @Test("A file fraction drives the bar, short of the end, while the amount still counts statements")
    func fileFractionDrivesTheBar() {
        let reading = TransferProgress(
            job: .dataImport, completed: 1, total: 40, unit: .statements, isEstimate: true, fileFraction: 0.6
        )
        let past = TransferProgress(job: .dataImport, completed: 40, total: 40, unit: .statements, fileFraction: 1.4)

        #expect(reading.fraction == 0.6)
        #expect(reading.amountText == "1 of about 40 statements")
        #expect(past.fraction == 0.99)
        #expect(past.amountText == "40 of 40 statements")
    }

    @Test("Counts pick the singular where the number is one")
    func singular() {
        #expect(TransferProgress(job: .export, completed: 1, unit: .rows).amountText == "1 row")
        #expect(TransferProgress(job: .export, completed: 1, total: 1, unit: .objects).amountText == "1 of 1 object")
        #expect(
            TransferProgress(job: .dataImport, completed: 1, unit: .statements).amountText
                == "1 statement"
        )
    }

    @Test("Bytes read as file sizes, and an estimated byte total is never quoted")
    func bytes() {
        let exact = TransferProgress(job: .restore, completed: 1_000_000, total: 4_000_000, unit: .bytes)
        let estimated = TransferProgress(
            job: .backup(databaseCount: 1), completed: 1_000_000, total: 4_000_000, unit: .bytes, isEstimate: true
        )
        let megabyte = ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .file)
        let fourMegabytes = ByteCountFormatter.string(fromByteCount: 4_000_000, countStyle: .file)

        #expect(exact.amountText == "\(megabyte) of \(fourMegabytes)")
        #expect(exact.fraction == 0.25)
        #expect(estimated.amountText == megabyte)
    }

    @Test("A step of several names the item's place, and one of one is left out")
    func step() {
        let several = TransferProgress(job: .export, item: "orders", step: .init(index: 2, count: 3), unit: .rows)
        let single = TransferProgress(job: .export, item: "orders", step: .init(index: 1, count: 1), unit: .rows)

        #expect(several.itemText == "orders (2 of 3)")
        #expect(single.itemText == "orders")
        #expect(TransferProgress(job: .objectCopy, item: "", unit: .rows).itemText == "Preparing…")
    }

    @Test("Each job reads as one verb")
    func titles() {
        #expect(TransferJob.export.title == "Exporting")
        #expect(TransferJob.dataImport.title == "Importing")
        #expect(TransferJob.backup(databaseCount: 1).title == "Backing Up")
        #expect(TransferJob.restore.title == "Restoring")
        #expect(TransferJob.tableTransfer(wrapsEachTable: true).title == "Transferring")
        #expect(TransferJob.objectCopy.title == "Copying")
    }

    @Test("A job that leaves nothing behind cancels, one that leaves what it did stops")
    func stopActions() {
        #expect(TransferJob.export.stopPolicy.action == .stop)
        #expect(TransferJob.backup(databaseCount: 1).stopPolicy.action == .cancel)
        #expect(TransferJob.dataImport.stopPolicy.action == .stop)
        #expect(TransferJob.backup(databaseCount: 3).stopPolicy.action == .stop)
        #expect(TransferJob.restore.stopPolicy.action == .stop)
        #expect(TransferJob.tableTransfer(wrapsEachTable: true).stopPolicy.action == .stop)
        #expect(TransferJob.objectCopy.stopPolicy.action == .stop)

        let cancel = TransferJob.backup(databaseCount: 1).stopPolicy
        let stop = TransferJob.restore.stopPolicy
        #expect(cancel.buttonTitle == "Cancel")
        #expect(cancel.stoppingTitle == "Cancelling…")
        #expect(stop.buttonTitle == "Stop")
        #expect(stop.stoppingTitle == "Stopping…")
    }

    @Test("Each confirmation says what the job really leaves")
    func consequences() {
        #expect(TransferJob.export.stopPolicy.consequence == "Partial files may remain on disk.")
        #expect(TransferJob.dataImport.stopPolicy.consequence == "Anything already imported may stay.")
        #expect(TransferJob.backup(databaseCount: 1).stopPolicy.consequence == "The partial backup file is removed.")
        #expect(
            TransferJob.backup(databaseCount: 2).stopPolicy.consequence
                == "Backups already written stay. The partial file is removed."
        )
        #expect(TransferJob.restore.stopPolicy.consequence == "The database may be left partly restored.")
        #expect(
            TransferJob.tableTransfer(wrapsEachTable: true).stopPolicy.consequence
                == "Tables already transferred stay."
        )
        #expect(TransferJob.tableTransfer(wrapsEachTable: false).stopPolicy.consequence == "Rows already transferred stay.")
        #expect(TransferJob.objectCopy.stopPolicy.consequence == "Objects already copied stay.")
        #expect(TransferJob.export.stopPolicy.confirmationTitle == "Stop Export?")
        #expect(TransferJob.restore.stopPolicy.confirmButton == "Stop Restore")
    }

    @Test("An export's estimate note sits under the bar and never replaces the counts")
    func exportNoteKeepsTheCounts() {
        var state = ExportState(isExporting: true, currentTable: "orders", currentTableIndex: 2, totalTables: 3)
        state.processedRows = 500
        state.totalRows = 2_000
        state.rowTotalIsEstimate = true
        state.estimateNote = "Progress estimated (1 table could not be counted)"

        let progress = state.transferProgress(fileName: "shop")

        #expect(progress.itemText == "orders (2 of 3)")
        #expect(progress.amountText == "500 of about \(grouped(2_000)) rows")
        #expect(progress.note == "Progress estimated (1 table could not be counted)")
        #expect(progress.fraction == 0.25)
    }

    @Test("A structure-only export counts objects")
    func structureOnlyExport() {
        var state = ExportState(isExporting: true, currentTable: "orders", currentTableIndex: 2, totalTables: 4)
        state.readsRows = false

        let progress = state.transferProgress(fileName: "shop")

        #expect(progress.unit == .objects)
        #expect(progress.amountText == "2 of 4 objects")
        #expect(progress.fraction == 0.5)
    }

    @Test("A row import counts rows, a statement file counts statements")
    func importUnits() {
        var rows = ImportState(isImporting: true, processedStatements: 3, fileName: "people.csv")
        rows.countsRows = true
        let statements = ImportState(isImporting: true, processedStatements: 3, fileName: "dump.sql")

        #expect(rows.transferProgress.amountText == "3 rows")
        #expect(statements.transferProgress.amountText == "3 statements")
        #expect(statements.transferProgress.itemText == "dump.sql")
    }
}
