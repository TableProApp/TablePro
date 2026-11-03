//
//  ImportProgressView.swift
//  TablePro
//

import SwiftUI

struct ImportProgressView: View {
    @ObservedObject var service: ImportService
    let onStop: () -> Void

    var body: some View {
        TransferProgressSheet(progress: service.state.transferProgress, onStop: onStop)
    }
}

extension ImportState {
    var transferProgress: TransferProgress {
        TransferProgress(
            job: .dataImport(rollsBackOnStop: rollsBackOnStop),
            item: fileName,
            step: TransferProgress.Step(index: fileIndex + 1, count: fileCount),
            completed: Int64(processedStatements),
            total: Int64(estimatedTotalStatements),
            unit: countsRows ? .rows : .statements,
            isEstimate: totalIsEstimate,
            note: statusMessage
        )
    }
}
