import SwiftUI

// Determinate whenever a total is known; indeterminate only while the run is still counting or preparing.
struct TransferProgressSection: View {
    let progress: TransferProgress

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let fraction = shownFraction {
                    ProgressView(value: fraction) {
                        Text(verbatim: TransferProgressText.headline(progress))
                    } currentValueLabel: {
                        Text(verbatim: TransferProgressText.counts(progress))
                            .monospacedDigit()
                    }
                } else {
                    HStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: TransferProgressText.headline(progress))
                            Text(verbatim: TransferProgressText.counts(progress))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                if let status = progress.status, !status.isEmpty {
                    Text(verbatim: status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
    }

    private var shownFraction: Double? {
        switch progress.stage {
        case .preparing, .counting:
            return nil
        case .running, .finishing:
            return progress.fractionCompleted
        }
    }
}

nonisolated enum TransferProgressText {
    static func headline(_ progress: TransferProgress) -> String {
        switch progress.stage {
        case .preparing:
            return String(localized: "Preparing…")
        case .counting:
            return String(localized: "Counting rows…")
        case .running, .finishing:
            guard let name = progress.objectName, !name.isEmpty else {
                return progress.stage == .finishing ? String(localized: "Finishing…") : String(localized: "Working…")
            }
            guard progress.objectCount > 1 else { return name }
            return String(
                format: String(localized: "%1$@ (%2$lld of %3$lld)"),
                name, Int64(progress.objectIndex), Int64(progress.objectCount)
            )
        }
    }

    static func counts(_ progress: TransferProgress) -> String {
        let completed = progress.completedUnits.formatted()
        guard let total = progress.totalUnits else {
            if progress.completedUnits == 0, let read = progress.bytesRead, let size = progress.totalBytes, size > 0 {
                return String(
                    format: String(localized: "%1$@ of %2$@"),
                    ByteCountFormatter.string(fromByteCount: read, countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                )
            }
            switch progress.unit {
            case .rows: return String(format: String(localized: "%@ rows"), completed)
            case .statements: return String(format: String(localized: "%@ statements"), completed)
            }
        }
        let shownTotal = max(total, progress.completedUnits).formatted()
        switch progress.unit {
        case .rows: return String(format: String(localized: "%1$@ of %2$@ rows"), completed, shownTotal)
        case .statements: return String(format: String(localized: "%1$@ of %2$@ statements"), completed, shownTotal)
        }
    }
}
