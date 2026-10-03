import Foundation
import os

struct HanaHelperConnectDeadline: Sendable {
    struct OpenPhase: Sendable {
        let configuration: Data
        let timeout: TimeInterval
    }

    private struct Configuration: Decodable {
        let connectTimeoutSeconds: TimeInterval
    }

    private static let minimumTimeout: TimeInterval = 0.001

    private let expiration: ContinuousClock.Instant

    init(
        configuration: Data,
        timeoutOverride: TimeInterval? = nil,
        now: ContinuousClock.Instant = .now
    ) {
        let configured = try? JSONDecoder().decode(Configuration.self, from: configuration).connectTimeoutSeconds
        let timeout = Self.valid(timeoutOverride)
            ?? Self.valid(configured)
            ?? HanaConnectConfiguration.defaultConnectTimeoutSeconds
        let milliseconds = Int64((timeout * 1_000).rounded(.up))
        expiration = now.advanced(by: .milliseconds(max(1, milliseconds)))
    }

    func handshakeTimeout(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        remainingTimeout(at: now)
    }

    func openTimeout(at now: ContinuousClock.Instant = .now) -> TimeInterval {
        remainingTimeout(at: now)
    }

    func openPhase(
        configuration: Data,
        at now: ContinuousClock.Instant = .now
    ) -> OpenPhase {
        let timeout = openTimeout(at: now)
        guard let decoded = try? JSONSerialization.jsonObject(with: configuration),
              var object = decoded as? [String: Any] else {
            return OpenPhase(configuration: configuration, timeout: timeout)
        }
        object["connectTimeoutSeconds"] = timeout
        let remainingConfiguration = (try? JSONSerialization.data(withJSONObject: object)) ?? configuration
        return OpenPhase(configuration: remainingConfiguration, timeout: timeout)
    }

    private func remainingTimeout(at now: ContinuousClock.Instant) -> TimeInterval {
        guard now < expiration else { return Self.minimumTimeout }
        let components = now.duration(to: expiration).components
        let seconds = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        return max(Self.minimumTimeout, seconds)
    }

    private static func valid(_ timeout: TimeInterval?) -> TimeInterval? {
        guard let timeout, timeout.isFinite, timeout > 0 else { return nil }
        return min(timeout, TimeInterval(Int32.max))
    }
}

final class HanaHelperBridge: HanaNativeBridge, @unchecked Sendable {
    static let cancelDeadlineMargin: TimeInterval = 10

    private struct Helper {
        let process: HanaHelperProcess
        let cancelDeadline: TimeInterval
    }

    private struct Route {
        let helper: Helper
        let session: UInt64
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "HanaHelperBridge")

    private let trust: HanaHelperTrust
    private let locateExecutable: @Sendable () throws -> URL
    private let cancelDeadlineOverride: TimeInterval?
    private let openDeadlineOverride: TimeInterval?
    private let lock = NSLock()
    private var routes: [UInt64: Route] = [:]
    private var lastSession: UInt64 = 0

    init(
        trust: HanaHelperTrust = .host,
        cancelDeadline: TimeInterval? = nil,
        openDeadline: TimeInterval? = nil,
        locateExecutable: (@Sendable () throws -> URL)? = nil
    ) {
        self.trust = trust
        self.cancelDeadlineOverride = cancelDeadline
        self.openDeadlineOverride = openDeadline
        self.locateExecutable = locateExecutable ?? {
            try trust.verifiedExecutable(in: Bundle(for: HanaPluginDriver.self))
        }
    }

    deinit {
        shutdown()
    }

    func helperProcessIdentifier(serving session: UInt64) -> pid_t? {
        lock.withLock { routes[session]?.helper.process.processIdentifier }
    }

    static func cancelDeadline(forcedSeverGrace: TimeInterval) -> TimeInterval {
        forcedSeverGrace + cancelDeadlineMargin
    }

    func open(configuration: Data, interruption: HanaOpenInterruption) throws -> UInt64 {
        guard !interruption.isInterrupted else { throw HanaHelperProcess.interruptedFailure }
        let deadline = HanaHelperConnectDeadline(
            configuration: configuration,
            timeoutOverride: openDeadlineOverride
        )
        let helper = try launchHelper(deadline: deadline, interruption: interruption)
        let remoteSession: UInt64
        do {
            remoteSession = try openSession(
                on: helper,
                configuration: configuration,
                deadline: deadline,
                interruption: interruption
            )
        } catch {
            helper.process.shutdown()
            throw error
        }
        Self.logger.debug("SAP HANA helper \(helper.process.processIdentifier) is serving this connection")
        return lock.withLock {
            lastSession &+= 1
            routes[lastSession] = Route(helper: helper, session: remoteSession)
            return lastSession
        }
    }

    func connect(_ ticket: HanaOperationTicket) throws -> Data {
        try call(.connect, ticket: ticket) { HanaHelperMessage.operation($0) }
    }

    func execute(_ ticket: HanaOperationTicket, request: Data) throws -> Data {
        try call(.execute, ticket: ticket) { HanaHelperMessage.statement($0, request: request) }
    }

    func explain(_ ticket: HanaOperationTicket, request: Data) throws -> Data {
        try call(.explain, ticket: ticket) { HanaHelperMessage.statement($0, request: request) }
    }

    func ping(_ ticket: HanaOperationTicket) throws {
        _ = try call(.ping, ticket: ticket) { HanaHelperMessage.operation($0) }
    }

    func cancel(_ ticket: HanaOperationTicket) {
        guard let route = lock.withLock({ routes[ticket.session] }) else { return }
        let remoteTicket = HanaOperationTicket(session: route.session, operation: ticket.operation)
        let process = route.helper.process
        guard let cancelFrame = process.post(.cancel, body: HanaHelperMessage.operation(remoteTicket)) else { return }
        let watch = HanaHelperCancelWatch(ticket: remoteTicket, issuedThrough: cancelFrame)
        let deadline = route.helper.cancelDeadline
        let cause = "TablePro stopped the SAP HANA helper because a cancelled operation was still running "
            + "\(HanaHelperDuration.secondsText(deadline)) seconds later."
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline) { [weak process] in
            process?.stop(ifStillPending: watch, cause: cause)
        }
    }

    func close(session: UInt64) {
        guard let route = lock.withLock({ routes.removeValue(forKey: session) }) else { return }
        route.helper.process.post(.close, body: HanaHelperMessage.session(route.session))
        route.helper.process.shutdown()
    }

    func shutdown() {
        let retired = lock.withLock { () -> [Route] in
            let retired = Array(routes.values)
            routes.removeAll()
            return retired
        }
        retired.forEach { $0.helper.process.shutdown() }
    }

    private func call(
        _ opcode: HanaHelperOpcode,
        ticket: HanaOperationTicket,
        body: (HanaOperationTicket) -> Data
    ) throws -> Data {
        guard let route = lock.withLock({ routes[ticket.session] }) else { throw HanaBridgeFailure.closed }
        let remoteTicket = HanaOperationTicket(session: route.session, operation: ticket.operation)
        return try route.helper.process.call(opcode, body: body(remoteTicket), ticket: remoteTicket)
    }

    private func openSession(
        on helper: Helper,
        configuration: Data,
        deadline: HanaHelperConnectDeadline,
        interruption: HanaOpenInterruption
    ) throws -> UInt64 {
        let phase = deadline.openPhase(configuration: configuration)
        let seconds = HanaHelperDuration.secondsText(phase.timeout.rounded(.up))
        let reply = try helper.process.call(
            .open,
            body: phase.configuration,
            within: phase.timeout,
            interruption: interruption,
            lateness: "The SAP HANA helper did not answer the connection request within \(seconds) seconds."
        )
        return try HanaHelperMessage.openedSession(from: reply)
    }

    private func launchHelper(
        deadline: HanaHelperConnectDeadline,
        interruption: HanaOpenInterruption
    ) throws -> Helper {
        let (process, greeting) = try HanaHelperProcess.launch(
            executable: locateExecutable(),
            handshakeDeadline: deadline.handshakeTimeout(),
            interruption: interruption
        )
        do {
            try trust.verifyRunningHelper(process.processIdentifier)
        } catch {
            Self.logger.error("SAP HANA helper \(process.processIdentifier) failed its code signature check")
            process.stop(cause: "TablePro stopped the SAP HANA helper because its code signature check failed.")
            throw error
        }
        let cancelDeadline = cancelDeadlineOverride
            ?? Self.cancelDeadline(forcedSeverGrace: greeting.forcedSeverGrace)
        return Helper(process: process, cancelDeadline: cancelDeadline)
    }
}
