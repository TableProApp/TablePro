//
//  CopyObjectsSheet.swift
//  TablePro
//
//  Copy To, and Duplicate Database, in one sheet.
//
//  Two steps, not one: the issue asks for the script to be shown before
//  anything runs, and the script cannot be built without reaching both
//  databases. Configuring costs nothing, so it stays free to change; Continue
//  is what pays for the reads, and Copy is what writes.
//

import SwiftUI

internal struct CopyObjectsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var session: ObjectCopySession
    @State private var isChoosingTarget = false

    internal init(launch: ObjectCopyLaunchRequest, connection: DatabaseConnection) {
        _session = State(initialValue: ObjectCopySession(
            mode: launch.mode,
            source: launch.source,
            sourceConnection: connection,
            preselected: launch.preselected
        ))
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .task {
            await session.loadObjects()
            await session.loadCreateDatabaseForm()
        }
        /// Escape has to leave every step. Three of the four carry a button that owns it, and the
        /// result step's only button owns Return instead, so the key would otherwise die there.
        /// A copy in flight is never abandoned by a keystroke that missed its Stop button: the
        /// sheet is the only thing reporting what the run is doing.
        .onExitCommand {
            guard session.step != .copying else { return }
            close()
        }
    }

    /// Leaving cancels the work the sheet started. `review()` holds a task that reads both
    /// databases and promotes its weak `self` to a strong one before the first await, so
    /// dismissing without this leaves the session and its metadata reads alive with nothing left
    /// to show them to. `backToConfiguring()` already cancels; the two exits have to agree.
    private func close() {
        session.cancel()
        dismiss()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.title)
                .font(.title3.weight(.semibold))
            Text(session.source.qualifiedDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch session.step {
        case .configuring:
            CopyObjectsConfigureView(session: session, isChoosingTarget: $isChoosingTarget)
        case .reviewing:
            CopyObjectsReviewView(session: session)
        case .copying:
            CopyObjectsProgressView(session: session)
        case .finished:
            CopyObjectsResultView(session: session)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        DialogFooter {
            statusText
        } actions: {
            actionButtons
        }
        .padding(20)
    }

    @ViewBuilder
    private var statusText: some View {
        if let message = session.errorMessage {
            /// A driver's message is the only account of what went wrong, and it is routinely
            /// longer than two lines, so it stays selectable and reachable in full from the
            /// pointer rather than being truncated into something nobody can act on.
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(message)
        } else if session.step == .configuring, let reason = session.reviewDisabledReason {
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.step {
        case .configuring:
            Button(String(localized: "Cancel"), role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Continue")) { session.review() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.reviewDisabledReason != nil)
        case .reviewing:
            /// Reading the script is where a user decides against the whole copy, so leaving is a
            /// button here rather than two presses through the step before it.
            Button(String(localized: "Cancel"), role: .cancel) { close() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Back")) { session.backToConfiguring() }
            Button(String(localized: "Copy")) { session.start() }
                .keyboardShortcut(.defaultAction)
                .disabled(session.plan == nil)
        case .copying:
            Button(String(localized: "Stop")) { session.cancel() }
                .keyboardShortcut(.cancelAction)
        case .finished:
            Button(String(localized: "Done")) { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// What the sidebar hands the sheet.
internal struct ObjectCopyLaunchRequest: Hashable, Identifiable, Sendable {
    internal let mode: ObjectCopyMode
    internal let source: DatabaseEndpoint
    /// Empty means every object in the source, which is what a right-click on a database means.
    internal let preselected: [ObjectCopySelection]

    internal init(mode: ObjectCopyMode, source: DatabaseEndpoint, preselected: [ObjectCopySelection] = []) {
        self.mode = mode
        self.source = source
        self.preselected = preselected
    }

    internal var id: String {
        let names = preselected.map(\.id).sorted().joined(separator: ",")
        return "\(mode)|\(source.id)|\(names)"
    }
}
