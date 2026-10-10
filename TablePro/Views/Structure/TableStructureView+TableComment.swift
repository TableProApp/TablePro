//
//  TableStructureView+TableComment.swift
//  TablePro
//

import AppKit
import os
import SwiftUI

internal extension TableStructureView {
    var tableCommentSupport: DatabaseObjectToolEligibility.Support {
        DatabaseObjectToolEligibility.Support.of(DatabaseManager.shared.driver(for: connection.id))
    }

    var offersTableComment: Bool {
        tableCommentSupport.commentableTypes.contains(objectKind)
    }

    var tableCommentField: StructureTableCommentPolicy.Field? {
        StructureTableCommentPolicy.resolve(
            objectKind: objectKind,
            support: tableCommentSupport,
            isReadOnly: toolbarState.safeModeLevel.blocksAllWrites,
            load: session.tableComment.erased,
            isSaving: structureChangeManager.isHeldForSave
        )
    }

    /// One model write per keystroke, so the staged change and its undo run never see a stale value.
    private var tableCommentBinding: Binding<String> {
        Binding(
            get: { structureChangeManager.tableComment.text },
            set: { structureChangeManager.stageTableComment($0) }
        )
    }

    @ViewBuilder
    var tableCommentBar: some View {
        if let field = tableCommentField {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Comment:")
                    .font(.body.weight(.medium))

                TextField(field.placeholder, text: tableCommentBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .disabled(!field.isEditable)
                    .focused($isTableCommentFocused)
                    .onSubmit { structureChangeManager.endTableCommentRun() }
                    .help(field.unavailableReason ?? "")
                    .accessibilityLabel(String(localized: "Comment"))
                    .accessibilityIdentifier("structure-table-comment")
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()
        }
    }

    func loadTableComment() async {
        guard offersTableComment else { return }
        session.beginTableCommentLoad()
        let outcome: MetadataFetchOutcome<String?>
        do {
            outcome = .fetched(try await structureLoader.tableComment())
        } catch {
            switch StructureFetchFailure(error, taskIsCancelled: Task.isCancelled) {
            case .cancelled:
                outcome = .cancelled
            case .failed(let message):
                Self.logger.error("Failed to load the table comment: \(error.publicLogShape, privacy: .public)")
                outcome = .failed(message)
            }
        }
        session.settleTableComment(outcome)
    }

    /// A comment changed elsewhere refetches columns identical to the ones loaded, so the columns'
    /// own handler never fires and the baseline has to move here.
    func onTableCommentChanged() {
        rebaselineUnlessEdited()
    }
}
