//
//  ResultComparisonModel.swift
//  TablePro
//

import Combine
import Foundation

internal struct ResultComparisonCandidate: Identifiable {
    internal let id: UUID
    internal let title: String
    internal let group: String
    internal let isPinned: Bool
    internal let read: @MainActor () -> ResultComparisonSide?
}

internal enum ResultComparisonFilter: CaseIterable, Hashable {
    case all
    case difference
    case onlyLeft
    case onlyRight
    case changed
    case same

    internal var title: String {
        switch self {
        case .all: return String(localized: "All Rows")
        case .difference: return String(localized: "Difference")
        case .onlyLeft: return String(localized: "Only Left")
        case .onlyRight: return String(localized: "Only Right")
        case .changed: return String(localized: "Changed")
        case .same: return String(localized: "Same")
        }
    }

    internal func matches(_ kind: ResultRowDifference) -> Bool {
        switch self {
        case .all: return true
        case .difference: return kind.isDifference
        case .onlyLeft: return kind == .onlyLeft
        case .onlyRight: return kind == .onlyRight
        case .changed: return kind == .changed
        case .same: return kind == .same
        }
    }
}

internal enum ResultComparisonIdleReason: Equatable {
    case noCandidates
    case notChosen
    case rightClosed
    case noCommonColumns
}

// The answer travels with the side and pairing it indexes into, so a grid never reads one answer through another pair.
internal struct ResultComparisonAnswer {
    internal let right: ResultComparisonSide
    internal let pairing: ResultColumnPairing
    internal let comparison: ResultComparison
}

@MainActor
internal final class ResultComparisonModel: ObservableObject {
    internal enum State {
        case idle(ResultComparisonIdleReason)
        case comparing
        case compared(ResultComparisonAnswer)
        case failed(String)
    }

    internal let left: ResultComparisonSide

    @Published private(set) var candidates: [ResultComparisonCandidate] = []
    @Published private(set) var rightId: UUID?
    @Published private(set) var right: ResultComparisonSide?
    @Published private(set) var pairing: ResultColumnPairing?
    @Published private(set) var keyPairs: [Int] = []
    @Published private(set) var state: State = .idle(.notChosen)
    @Published private(set) var isRefreshing = false
    @Published var filter: ResultComparisonFilter = .difference

    private let candidateSource: @MainActor () -> [ResultComparisonCandidate]
    private var comparisonTask: Task<Void, Never>?

    internal init(
        left: ResultComparisonSide,
        preferredRightId: UUID?,
        candidates: @escaping @MainActor () -> [ResultComparisonCandidate]
    ) {
        self.left = left
        self.candidateSource = candidates
        refreshCandidates()
        chooseRight(preferredRightId ?? self.candidates.first?.id)
    }

    internal var groupedCandidates: [(group: String, candidates: [ResultComparisonCandidate])] {
        var groups: [(group: String, candidates: [ResultComparisonCandidate])] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { $0.group == candidate.group }) {
                groups[index].candidates.append(candidate)
            } else {
                groups.append((candidate.group, [candidate]))
            }
        }
        return groups
    }

    internal var answer: ResultComparisonAnswer? {
        guard case .compared(let answer) = state else { return nil }
        return answer
    }

    internal var comparison: ResultComparison? {
        answer?.comparison
    }

    // A closed result keeps its entry while it is the one on screen, so the picker never goes blank under it.
    internal func refreshCandidates() {
        var fresh = candidateSource()
        if let rightId, !fresh.contains(where: { $0.id == rightId }),
           let current = candidates.first(where: { $0.id == rightId }) {
            fresh.append(current)
        }
        candidates = fresh
        if rightId == nil {
            state = .idle(candidates.isEmpty ? .noCandidates : .notChosen)
        }
    }

    internal func chooseRight(_ id: UUID?) {
        guard let id else {
            rightId = nil
            right = nil
            pairing = nil
            state = .idle(candidates.isEmpty ? .noCandidates : .notChosen)
            return
        }
        guard id != rightId || right == nil else { return }
        rightId = id
        guard let side = candidates.first(where: { $0.id == id })?.read() else {
            cancel()
            right = nil
            pairing = nil
            state = .idle(.rightClosed)
            return
        }
        right = side
        let pairing = ResultColumnPairing(left: left.columns, right: side.columns)
        self.pairing = pairing
        keyPairs = ResultComparisonEngine.defaultKeyPairs(left: left, right: side, pairing: pairing)
        compare(keepingAnswer: false)
    }

    internal func isKey(_ pairIndex: Int) -> Bool {
        keyPairs.contains(pairIndex)
    }

    internal func toggleKey(_ pairIndex: Int) {
        guard let pairing, pairing.pairs.indices.contains(pairIndex) else { return }
        if let position = keyPairs.firstIndex(of: pairIndex) {
            keyPairs.remove(at: position)
        } else {
            keyPairs = (keyPairs + [pairIndex]).sorted()
        }
        compare(keepingAnswer: true)
    }

    internal func matchWholeRows() {
        guard !keyPairs.isEmpty else { return }
        keyPairs = []
        compare(keepingAnswer: true)
    }

    internal func cancel() {
        comparisonTask?.cancel()
        comparisonTask = nil
        isRefreshing = false
    }

    // A new key re-answers the same pair, so the grid keeps the last answer until the next one lands.
    private func compare(keepingAnswer: Bool) {
        cancel()
        guard let right, let pairing else { return }
        guard !pairing.pairs.isEmpty else {
            state = .idle(.noCommonColumns)
            return
        }
        if keepingAnswer, answer != nil {
            isRefreshing = true
        } else {
            state = .comparing
        }
        let left = left
        let keyPairs = keyPairs
        comparisonTask = Task { [weak self] in
            let outcome = await Self.run(left: left, right: right, pairing: pairing, keyPairs: keyPairs)
            guard !Task.isCancelled, let self else { return }
            isRefreshing = false
            switch outcome {
            case .success(let comparison):
                state = .compared(ResultComparisonAnswer(right: right, pairing: pairing, comparison: comparison))
            case .failure(let error as ResultComparisonError):
                state = .failed(error.localizedDescription)
            case .failure:
                return
            }
        }
    }

    @concurrent
    nonisolated private static func run(
        left: ResultComparisonSide,
        right: ResultComparisonSide,
        pairing: ResultColumnPairing,
        keyPairs: [Int]
    ) async -> Result<ResultComparison, Error> {
        Result { try ResultComparisonEngine.compare(left: left, right: right, pairing: pairing, keyPairs: keyPairs) }
    }
}
