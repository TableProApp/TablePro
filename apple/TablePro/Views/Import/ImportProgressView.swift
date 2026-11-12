//
//  ImportProgressView.swift
//  TablePro
//

import SwiftUI

struct ImportProgressView: View {
    @ObservedObject var service: ImportService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TransferProgressView(progress: service.state.transferProgress)
            HStack {
                Spacer()
                Button(buttonTitle) { service.requestStop() }
                    .disabled(service.stopPhase != .running)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .controlSize(.regular)
        .padding(20)
        .frame(width: TransferProgressSheet.width)
        .interactiveDismissDisabled()
        .alert(String(localized: "Stop Import?"), isPresented: questionPresented, presenting: service.stopQuestion) { question in
            if question.ledger.canChooseCommit {
                Button(String(localized: "Stop and Rollback"), role: .destructive) {
                    service.answerStop(.rollBack, generation: question.generation)
                }
                Button(String(localized: "Stop and Commit")) {
                    service.answerStop(.commit, generation: question.generation)
                }
            } else {
                Button(String(localized: "Stop Import"), role: .destructive) {
                    service.answerStop(.rollBack, generation: question.generation)
                }
            }
            Button(String(localized: "Continue"), role: .cancel) {
                service.answerStop(nil, generation: question.generation)
            }
        } message: { question in
            Text(question.ledger.question)
        }
        .onDisappear { service.stopUnansweredQuestion() }
    }

    private var questionPresented: Binding<Bool> {
        Binding(get: { service.stopQuestion != nil }, set: { _ in })
    }

    private var buttonTitle: String {
        switch service.stopPhase {
        case .running: return String(localized: "Stop")
        case .pausing, .paused: return String(localized: "Pausing…")
        case .stopping, .finished: return String(localized: "Stopping…")
        }
    }
}

extension ImportState {
    var transferProgress: TransferProgress {
        TransferProgress(
            job: .dataImport,
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
