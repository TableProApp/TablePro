//
//  ResultComparisonView.swift
//  TablePro
//

import SwiftUI

internal struct ResultComparisonView: View {
    @ObservedObject internal var model: ResultComparisonModel

    @Environment(\.controlActiveState) private var controlActiveState

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            reviewBar
            notices
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: controlActiveState) { state in
            guard state == .key else { return }
            model.refreshCandidates()
        }
        .onDisappear { model.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(model.left.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.vertical, 2)
                    .accessibilityIdentifier("result-comparison.left")
                Text(model.left.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(.secondary)
                .padding(.top, 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                rightPicker
                if let right = model.right {
                    Text(right.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
    }

    private var rightPicker: some View {
        Picker(String(localized: "Compare With"), selection: Binding(
            get: { model.rightId },
            set: { model.chooseRight($0) }
        )) {
            if model.rightId == nil {
                Text("Choose a Result").tag(UUID?.none)
            }
            ForEach(model.groupedCandidates, id: \.group) { group in
                Section(group.group) {
                    ForEach(group.candidates) { candidate in
                        Text(candidate.title).tag(UUID?.some(candidate.id))
                    }
                }
            }
        }
        .labelsHidden()
        .disabled(model.candidates.isEmpty)
        .accessibilityIdentifier("result-comparison.right")
    }

    // MARK: - Review bar

    private var reviewBar: some View {
        HStack(spacing: 12) {
            keyColumnsMenu

            Picker(String(localized: "Show"), selection: $model.filter) {
                ForEach(ResultComparisonFilter.allCases, id: \.self) { option in
                    Text(option.title).tag(option)
                }
            }
            .fixedSize()
            .accessibilityIdentifier("result-comparison.show")

            Spacer(minLength: 0)

            if model.isRefreshing || isComparing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "Comparing"))
            }
            if let comparison = model.comparison {
                Text(countsSummary(comparison))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("result-comparison.counts")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var keyColumnsMenu: some View {
        LabeledContent(String(localized: "Key columns")) {
            Menu {
                if let pairing = model.pairing {
                    ForEach(pairing.pairs.indices, id: \.self) { index in
                        Toggle(pairing.pairs[index].name, isOn: Binding(
                            get: { model.isKey(index) },
                            set: { _ in model.toggleKey(index) }
                        ))
                    }
                    Divider()
                    Button("Match Whole Rows") { model.matchWholeRows() }
                        .disabled(model.keyPairs.isEmpty)
                }
            } label: {
                Label(keySummary, systemImage: "key")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 240)
            .help(String(localized: "Rows with the same values in these columns are compared. With none chosen, whole rows are matched."))
            .accessibilityIdentifier("result-comparison.key")
        }
        .disabled(model.pairing?.pairs.isEmpty ?? true)
    }

    private var isComparing: Bool {
        guard case .comparing = model.state else { return false }
        return true
    }

    private var keySummary: String {
        guard let pairing = model.pairing, !model.keyPairs.isEmpty else {
            return String(localized: "Whole row")
        }
        return model.keyPairs.map { pairing.pairs[$0].name }.joined(separator: ", ")
    }

    private func countsSummary(_ comparison: ResultComparison) -> String {
        String(
            format: String(localized: "%1$d only left, %2$d only right, %3$d changed, %4$d same"),
            comparison.count(of: .onlyLeft),
            comparison.count(of: .onlyRight),
            comparison.count(of: .changed),
            comparison.count(of: .same)
        )
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let truncation = truncationNotice {
            notice(truncation, systemImage: "info.circle")
        }
        if let pairing = model.pairing, !pairing.pairs.isEmpty {
            if !pairing.leftOnly.isEmpty {
                notice(
                    String(
                        format: String(localized: "Only in the left result, not compared: %@"),
                        pairing.leftOnly.joined(separator: ", ")
                    ),
                    systemImage: "info.circle"
                )
            }
            if !pairing.rightOnly.isEmpty {
                notice(
                    String(
                        format: String(localized: "Only in the right result, not compared: %@"),
                        pairing.rightOnly.joined(separator: ", ")
                    ),
                    systemImage: "info.circle"
                )
            }
        }
    }

    private var truncationNotice: String? {
        let leftCut = model.left.isTruncated
        let rightCut = model.right?.isTruncated ?? false
        switch (leftCut, rightCut) {
        case (true, true):
            return String(localized: "Both results stopped at the row cap and are compared on the rows they hold. A row past the cap can show as only on one side.")
        case (true, false):
            return String(
                format: String(localized: "The left result stopped at the row cap and is compared on the %@ rows it holds. A row past the cap can show as only on the right."),
                model.left.rows.count.formatted()
            )
        case (false, true):
            return String(
                format: String(localized: "The right result stopped at the row cap and is compared on the %@ rows it holds. A row past the cap can show as only on the left."),
                (model.right?.rows.count ?? 0).formatted()
            )
        case (false, false):
            return nil
        }
    }

    private func notice(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .compared(let answer):
            if answer.comparison.entries.contains(where: { model.filter.matches($0.kind) }) {
                ResultComparisonGrid(
                    comparison: answer.comparison,
                    left: model.left,
                    right: answer.right,
                    pairing: answer.pairing,
                    filter: model.filter
                )
            } else {
                CompareRowsStandIn(reason: .noRowsMatch)
            }
        case .comparing:
            ProgressView(String(localized: "Comparing…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gridStandInBackground()
        case .failed(let message):
            standIn(String(localized: "Cannot Compare"), systemImage: "exclamationmark.triangle", description: message)
        case .idle(let reason):
            idleStandIn(reason)
        }
    }

    @ViewBuilder
    private func idleStandIn(_ reason: ResultComparisonIdleReason) -> some View {
        switch reason {
        case .noCandidates:
            standIn(
                String(localized: "No Result to Compare With"),
                systemImage: "tablecells",
                description: String(localized: "Run another query in this tab, or pin a result in another tab.")
            )
        case .notChosen:
            standIn(
                String(localized: "Choose a Result"),
                systemImage: "arrow.left.arrow.right",
                description: String(localized: "Pick the result to compare this one with.")
            )
        case .rightClosed:
            standIn(
                String(localized: "Result Closed"),
                systemImage: "xmark.circle",
                description: String(localized: "That result is no longer open. Choose another one.")
            )
        case .noCommonColumns:
            standIn(
                String(localized: "No Columns in Common"),
                systemImage: "tablecells",
                description: String(localized: "The two results share no column name, so there is nothing to compare.")
            )
        }
    }

    private func standIn(_ title: String, systemImage: String, description: String) -> some View {
        UnavailableStateView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
        .gridStandInBackground()
    }
}
