import Foundation
@testable import TableProMobile

@MainActor
final class RecordingSearchIndex: ConnectionSearchIndexing {
    enum Failure: Error {
        case scripted
    }

    private(set) var replacements: [[SearchableConnection]] = []
    private(set) var contents: [SearchableConnection] = []
    // Kept by the index across launches, as CoreSpotlight keeps a client state.
    private(set) var state: Data?
    private(set) var stateReads = 0
    private(set) var maxConcurrent = 0
    private var inFlight = 0
    private var failuresRemaining = 0
    private var stateReadFailures = 0
    private var holdsNext = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?

    var indexedIds: Set<UUID> {
        Set(contents.map(\.id))
    }

    func failNext() {
        failuresRemaining += 1
    }

    func failNextStateRead() {
        stateReadFailures += 1
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
    func storedState() async throws -> Data? {
        stateReads += 1
        if stateReadFailures > 0 {
            stateReadFailures -= 1
            throw Failure.scripted
        }
        return state
    }

    @MainActor
    func replaceConnections(with connections: [SearchableConnection], state: Data) async throws {
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
        self.state = state
    }
}
