//
//  CompareSyncSetupView.swift
//  TablePro
//
//  Picks the two endpoints. Neither picker is prefilled with a target, and a
//  read-only connection is refused as the target at selection time rather than
//  at apply time.
//

import SwiftUI

internal struct CompareSyncSetupView: View {
    @Bindable internal var session: CompareSyncSession

    @State private var candidates: [CompareSyncEndpoint] = []

    internal var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modePicker
                endpointPickers
                directionSummary
                optionsSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { candidates = CompareSyncEndpoint.candidates(from: ConnectionStorage.shared.loadConnections()) }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to compare")
                .font(.headline)
            Picker("", selection: $session.mode) {
                ForEach(CompareSyncMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .onChange(of: session.mode) { _, _ in session.resetComparison() }
        }
    }

    private var endpointPickers: some View {
        HStack(alignment: .top, spacing: 16) {
            endpointColumn(
                title: String(localized: "Source"),
                caption: String(localized: "Will not change"),
                selection: $session.source,
                isTarget: false
            )

            Button {
                session.swapEndpoints()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .help(String(localized: "Swap source and target"))
            .disabled(!session.canSwap)
            .padding(.top, 28)

            endpointColumn(
                title: String(localized: "Target"),
                caption: String(localized: "Will be changed"),
                selection: $session.target,
                isTarget: true
            )
        }
    }

    private func endpointColumn(
        title: String,
        caption: String,
        selection: Binding<CompareSyncEndpoint?>,
        isTarget: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(isTarget ? Color.orange : Color.secondary)
            }
            Picker("", selection: selection) {
                Text(String(localized: "Choose a connection")).tag(CompareSyncEndpoint?.none)
                ForEach(candidates) { candidate in
                    endpointRow(candidate, isTarget: isTarget)
                        .tag(CompareSyncEndpoint?.some(candidate))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: selection.wrappedValue) { _, _ in session.resetComparison() }

            if isTarget, let target = session.target, let reason = target.ineligibleAsTargetReason {
                Label(reason, systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func endpointRow(_ candidate: CompareSyncEndpoint, isTarget: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(candidate.color.color).frame(width: 8, height: 8)
            Text(candidate.qualifiedDescription)
            if isTarget, let reason = candidate.ineligibleAsTargetReason {
                Text(String(format: String(localized: "(%@)"), reason))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var directionSummary: some View {
        if let sentence = session.directionSentence {
            Label(sentence, systemImage: "arrow.right.circle.fill")
                .font(.callout)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        if let notice = session.crossEngineNotice {
            Label(notice, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var optionsSection: some View {
        if session.mode == .structure {
            StructureCompareOptionsView(session: session)
        } else {
            DataCompareOptionsView(session: session)
        }
    }
}

internal struct StructureCompareOptionsView: View {
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to ignore")
                .font(.headline)
            Text("These drift between environments by design. Turn one off to have the difference reported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Identifier case", isOn: $session.structureOptions.ignoreIdentifierCase)
            Toggle("Column order", isOn: $session.structureOptions.ignoreColumnOrder)
            Toggle("Whitespace in default values and comments", isOn: $session.structureOptions.ignoreWhitespaceInText)
            Toggle("Auto-increment seed value", isOn: $session.structureOptions.ignoreAutoIncrementSeed)
            Toggle("Collation and character set", isOn: $session.structureOptions.ignoreCollationAndCharset)
            Toggle("Comments, owners, and definers", isOn: $session.structureOptions.ignoreCommentsAndOwners)
        }
        .onChange(of: session.structureOptions) { _, _ in session.resetComparison() }
    }
}

internal struct DataCompareOptionsView: View {
    @Bindable internal var session: CompareSyncSession

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What to write")
                .font(.headline)

            Toggle("Insert rows missing from the target", isOn: $session.dataOptions.insertMissingRows)
            Toggle("Update rows that differ", isOn: $session.dataOptions.updateDifferingRows)
            Toggle("Delete rows the source does not have", isOn: $session.dataOptions.deleteExtraRows)

            Text("Delete is off by default so the first run cannot remove a row you did not mean to touch.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Text("How values are judged equal")
                .font(.headline)
            HStack {
                Text("Numeric tolerance")
                TextField("", value: $session.dataOptions.floatTolerance, format: .number)
                    .frame(width: 100)
            }
            HStack {
                Text("Timestamp fractional digits")
                Stepper(
                    value: $session.dataOptions.timestampFractionalDigits,
                    in: 0...9
                ) {
                    Text("\(session.dataOptions.timestampFractionalDigits)")
                }
                .frame(width: 120)
            }
        }
    }
}
