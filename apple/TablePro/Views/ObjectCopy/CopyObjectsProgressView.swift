//
//  CopyObjectsProgressView.swift
//  TablePro
//

import SwiftUI

internal struct CopyObjectsProgressView: View {
    @ObservedObject internal var session: ObjectCopySession

    internal var body: some View {
        TransferProgressView(progress: session.transferProgress)
            .frame(maxWidth: TransferProgressSheet.width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("copy-objects-progress")
    }
}

internal extension ObjectCopySession {
    // Several engines answer the row count from statistics, so the total is only ever about.
    var transferProgress: TransferProgress {
        TransferProgress(
            job: .objectCopy,
            item: currentObject,
            completed: Int64(copiedRows),
            total: plan.map { Int64($0.estimatedRowTotal) },
            unit: .rows,
            isEstimate: true
        )
    }
}
