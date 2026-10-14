import Foundation
@testable import TablePro
import TableProMCP
import TableProMCPTestSupport
import TableProPluginKit

actor ReleaseGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if released {
                continuation.resume()
                return
            }
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

actor MCPProtocolStubClock: MCPClock {
    private struct PendingSleep {
        let dueAt: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private var currentDate: Date
    private var pending: [UUID: PendingSleep] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private(set) var completedSleeps: Int = 0

    init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        currentDate = start
    }

    func now() -> Date {
        currentDate
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let dueAt = currentDate.addingTimeInterval(Self.seconds(of: duration))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelledBeforeRegistration.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[id] = PendingSleep(dueAt: dueAt, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSleep(id) }
        }
    }

    func advance(by duration: Duration) async {
        currentDate = currentDate.addingTimeInterval(Self.seconds(of: duration))
        resumeDueSleeps()
        await Task.yield()
    }

    func setNow(_ date: Date) async {
        currentDate = date
        resumeDueSleeps()
        await Task.yield()
    }

    func pendingSleepCount() -> Int {
        pending.count
    }

    private func cancelSleep(_ id: UUID) {
        guard let sleeper = pending.removeValue(forKey: id) else {
            cancelledBeforeRegistration.insert(id)
            return
        }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private func resumeDueSleeps() {
        let due = pending.filter { $0.value.dueAt <= currentDate }
        for (id, sleeper) in due {
            pending.removeValue(forKey: id)
            completedSleeps += 1
            sleeper.continuation.resume()
        }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1.0e18
    }
}

struct StubDriverError: LocalizedError, Sendable {
    let detail: String

    var errorDescription: String? {
        detail
    }
}

enum StubHandlerBehavior: Sendable {
    case returning(MCPResult)
    case failProtocol(MCPProtocolError)
    case failDriver(StubDriverError)
    case waitForCancellation
    case blockUntilReleased(ReleaseGate)
    case emitProgressThenComplete(Double)
    case requiringInput(MCPInputRequired)
}

protocol StubHandlerIdentity: Sendable {
    static var method: String { get }
    static var requiredScopes: Set<MCPScope> { get }
    static var isAvailableToLegacyClients: Bool { get }
}

extension StubHandlerIdentity {
    static var requiredScopes: Set<MCPScope> { [] }
    static var isAvailableToLegacyClients: Bool { true }
}

enum StubTestIdentity: StubHandlerIdentity {
    static let method = "test/stub"
}

enum StubModernOnlyIdentity: StubHandlerIdentity {
    static let method = "modern/only"
    static let isAvailableToLegacyClients = false
}

enum StubScopedIdentity: StubHandlerIdentity {
    static let method = "scoped/method"
    static let requiredScopes: Set<MCPScope> = [.admin, .toolsWrite]
}

enum StubToolsListIdentity: StubHandlerIdentity {
    static let method = "tools/list"
}

enum StubToolsCallIdentity: StubHandlerIdentity {
    static let method = "tools/call"
}

enum StubResourcesReadIdentity: StubHandlerIdentity {
    static let method = "resources/read"
}

struct StubHandler<Identity: StubHandlerIdentity>: MCPMethodHandler {
    static var method: String { Identity.method }
    static var requiredScopes: Set<MCPScope> { Identity.requiredScopes }
    static var isAvailableToLegacyClients: Bool { Identity.isAvailableToLegacyClients }

    let behavior: StubHandlerBehavior
    let started: ObservedFlag
    let observedCancellation: ObservedFlag

    init(behavior: StubHandlerBehavior = .returning(.complete(["ok": .bool(true)]))) {
        self.behavior = behavior
        started = ObservedFlag()
        observedCancellation = ObservedFlag()
    }

    func handle(params: JsonValue?, context: MCPRequestContext) async throws -> MCPResult {
        await started.set()
        switch behavior {
        case .returning(let result):
            return result
        case .failProtocol(let error):
            throw error
        case .failDriver(let error):
            throw error
        case .waitForCancellation:
            while true {
                if await context.cancellation.isCancelled {
                    await observedCancellation.set()
                    throw CancellationError()
                }
                try await Task.sleep(for: .milliseconds(5))
            }
        case .blockUntilReleased(let gate):
            await gate.wait()
            return .complete(["ok": .bool(true)])
        case .emitProgressThenComplete(let progress):
            await context.progress.emit(progress: progress)
            return .complete(["ok": .bool(true)])
        case .requiringInput(let signal):
            throw signal
        }
    }
}

typealias StubTestHandler = StubHandler<StubTestIdentity>
typealias StubModernOnlyHandler = StubHandler<StubModernOnlyIdentity>
typealias StubScopedHandler = StubHandler<StubScopedIdentity>
typealias StubToolsListHandler = StubHandler<StubToolsListIdentity>
typealias StubToolsCallHandler = StubHandler<StubToolsCallIdentity>
typealias StubResourcesReadHandler = StubHandler<StubResourcesReadIdentity>

extension MCPProtocolTestSupport {
    static func makeDispatcher(
        handlers: [any MCPMethodHandler],
        legacyAdapter: MCPLegacyEraAdapter = MCPLegacyEraAdapter(),
        clock: any MCPClock = MCPSystemClock(),
        handlerTimeout: Duration = .seconds(330),
        disconnectPollInterval: Duration = .seconds(60)
    ) -> MCPProtocolDispatcher {
        MCPProtocolDispatcher(
            handlers: handlers,
            legacyAdapter: legacyAdapter,
            activityLedger: MCPClientActivityLedger(),
            serverInfo: MCPImplementation(name: "tablepro", title: "TablePro", version: "1.2.3"),
            clock: clock,
            handlerTimeout: handlerTimeout,
            disconnectPollInterval: disconnectPollInterval
        )
    }
}
