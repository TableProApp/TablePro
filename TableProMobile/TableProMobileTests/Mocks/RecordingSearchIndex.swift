import Foundation
@testable import TableProMobile

@MainActor
final class RecordingSearchIndex: ConnectionSearchIndexing {
    enum Failure: Error {
        case scripted
    }

    private(set) var replacements: [[SearchableConnection]] = []
    private(set) var contents: [SearchableConnection] = []
    private(set) var maxConcurrent = 0
    private var inFlight = 0
    private var failuresRemaining = 0
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    var indexedIds: Set<UUID> {
        Set(contents.map(\.id))
    }

    func failNext() {
        failuresRemaining += 1
    }

    func holdNextReplace() {
        holdsNext = true
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    @MainActor
    func replaceConnections(with connections: [SearchableConnection]) async throws {
        inFlight += 1
        maxConcurrent = max(maxConcurrent, inFlight)
        defer { inFlight -= 1 }
        replacements.append(connections)
        if holdsNext {
            holdsNext = false
            await withCheckedContinuation { continuation in
                held = continuation
                heldWaiter?.resume()
                heldWaiter = nil
            }
        }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw Failure.scripted
        }
        contents = connections
    }
}
