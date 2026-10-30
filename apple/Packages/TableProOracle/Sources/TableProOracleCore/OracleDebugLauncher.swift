import Foundation
import os
import OSLog

private let logger = Logger(subsystem: "com.TablePro", category: "OracleDebugLauncher")

public struct OracleDebugLaunch: Sendable {
    public let entryPoint: OracleDebugEntryPoint
    public let arguments: [String: OracleDebugArgumentValue]
    public let breakpoints: [OracleDebugBreakpointRequest]
    public let preference: OracleDebugProtocolPreference
    public let debuggerHost: String
    public let ports: ClosedRange<UInt16>
    // The host the sessions dial, and any other name the server may connect back from (the server behind a tunnel).
    public let databaseHost: String
    public let databasePort: Int
    public let otherDatabaseHosts: [String]
    // Every overload of the entry point's subprogram, to refuse a call Oracle could not resolve.
    public let overloads: [OracleDebugEntryPoint]
    // How long the database gets to connect back before JDWP counts as unreachable.
    public let connectTimeout: Duration

    public init(
        entryPoint: OracleDebugEntryPoint,
        arguments: [String: OracleDebugArgumentValue],
        breakpoints: [OracleDebugBreakpointRequest],
        preference: OracleDebugProtocolPreference,
        debuggerHost: String,
        ports: ClosedRange<UInt16>,
        databaseHost: String,
        databasePort: Int,
        otherDatabaseHosts: [String] = [],
        overloads: [OracleDebugEntryPoint] = [],
        connectTimeout: Duration = .seconds(15)
    ) {
        self.entryPoint = entryPoint
        self.arguments = arguments
        self.breakpoints = breakpoints
        self.preference = preference
        self.debuggerHost = debuggerHost
        self.ports = ports
        self.databaseHost = databaseHost
        self.databasePort = databasePort
        self.otherDatabaseHosts = otherDatabaseHosts
        self.overloads = overloads
        self.connectTimeout = connectTimeout
    }
}

public struct OracleDebugBreakpointRequest: Sendable, Hashable {
    public let unit: OracleDebugUnit
    public let line: Int

    public init(unit: OracleDebugUnit, line: Int) {
        self.unit = unit
        self.line = line
    }
}

public enum OracleDebugLauncher {
    // Two sessions either way: JDWP's target plus one that reads source, DBMS_DEBUG's target plus its supervisor.
    // Cancelling the calling task ends whatever target exists, as Stop would, and throws CancellationError.
    public static func launch(
        _ launch: OracleDebugLaunch,
        openSession: @escaping @Sendable () async throws -> OracleCoreConnection
    ) async throws -> any OracleDebugEngine {
        try Task.checkCancellation()
        if OracleDebugProtocolDecision.initial(preference: launch.preference, host: launch.debuggerHost) == .fail {
            throw OracleDebugError.jdwp(.noDebuggerHost)
        }
        switch OracleDebugStatements.ambiguity(of: launch.entryPoint, arguments: launch.arguments, overloads: launch.overloads) {
        case .needsValue(let parameters):
            throw OracleDebugError.ambiguousDefaults(subprogram: launch.entryPoint.entry.subprogram, parameters: parameters)
        case .unresolvable:
            throw OracleDebugError.ambiguousCall(subprogram: launch.entryPoint.entry.subprogram)
        case nil:
            break
        }
        let invocation: OracleDebugStatements.Invocation
        do {
            invocation = try OracleDebugStatements.invocation(of: launch.entryPoint, arguments: launch.arguments)
        } catch OracleDebugStatements.InvocationError.unsupportedArgument(let name, let typeName) {
            throw OracleDebugError.unsupportedArgument(name: name, typeName: typeName)
        } catch OracleDebugStatements.InvocationError.undeclarableArgument(let name, let typeName) {
            throw OracleDebugError.undeclarableArgument(name: name, typeName: typeName)
        } catch OracleDebugStatements.InvocationError.undeclarableResult(let typeName) {
            throw OracleDebugError.undeclarableArgument(name: launch.entryPoint.entry.subprogram, typeName: typeName)
        }
        let helper = try await reserved(openSession)
        var target = try await reserved(openSession)
        let breakpoints = launch.breakpoints.map { (unit: $0.unit, line: $0.line) }
        var notices: [OracleDebugNotice] = []

        switch OracleDebugProtocolDecision.initial(preference: launch.preference, host: launch.debuggerHost) {
        case .dbmsDebug(let reason):
            notices.append(.usingDBMSDebug(reason: reason))
        default:
            do {
                let session = try await startJDWP(launch, invocation: invocation, target: target, helper: helper, breakpoints: breakpoints)
                return try await keep(session)
            } catch let failure as JDWPStartFailure {
                switch OracleDebugProtocolDecision.afterJDWPFailure(failure.reason, preference: launch.preference) {
                case .fallBack:
                    logger.notice("JDWP did not connect; falling back to DBMS_DEBUG")
                    notices.append(.fellBack(failure.reason, host: launch.debuggerHost, port: Int(failure.port ?? 0)))
                    try Task.checkCancellation()
                    if failure.endedTarget || !target.isConnected {
                        target = try await reserved(openSession)
                    }
                default:
                    throw OracleDebugError.jdwp(failure.reason)
                }
            }
        }

        let session = OracleDBMSDebugSession(
            target: target,
            supervisor: helper,
            entryPoint: launch.entryPoint,
            invocation: invocation,
            notices: notices
        )
        do {
            try await session.start(breakpoints: breakpoints)
        } catch {
            if Task.isCancelled {
                _ = await session.stop()
                throw CancellationError()
            }
            throw mapped(error)
        }
        return try await keep(session)
    }

    // A start the caller cancelled hands back no session, so the target ends here.
    private static func keep(_ engine: any OracleDebugEngine) async throws -> any OracleDebugEngine {
        guard Task.isCancelled else { return engine }
        _ = await engine.stop()
        throw CancellationError()
    }

    private static func reserved(_ openSession: @Sendable () async throws -> OracleCoreConnection) async throws -> OracleCoreConnection {
        let connection = try await openSession()
        connection.reserveForDebugging()
        return connection
    }

    struct JDWPStartFailure: Error {
        let reason: OracleJDWPFailure
        let port: UInt16?
        var endedTarget = false
    }

    // The addresses a connection back may come from: the server's own, and for a tunnel this Mac's loopback, where a
    // remote forward the person set up arrives.
    static func allowedPeers(for launch: OracleDebugLaunch) async -> Set<String> {
        var allowed: Set<String> = []
        for host in [launch.databaseHost] + launch.otherDatabaseHosts {
            allowed.formUnion(await OracleDebugNetwork.resolvedAddresses(of: host))
        }
        return allowed
    }

    private static func startJDWP(
        _ launch: OracleDebugLaunch,
        invocation: OracleDebugStatements.Invocation,
        target: OracleCoreConnection,
        helper: OracleCoreConnection,
        breakpoints: [(unit: OracleDebugUnit, line: Int)]
    ) async throws -> OracleJDWPDebugSession {
        let allowed = await allowedPeers(for: launch)
        let bindAddresses = await OracleDebugNetwork.bindAddresses(
            debuggerHost: launch.debuggerHost,
            databaseHost: launch.databaseHost,
            databasePort: launch.databasePort
        )
        let listener: OracleJDWPListener
        do {
            listener = try await OracleJDWPListener.open(ports: launch.ports, bindAddresses: bindAddresses, allowedPeers: allowed)
        } catch {
            throw JDWPStartFailure(reason: .noFreePort, port: nil)
        }
        let port = listener.port
        let identity = await OracleDebugSupport.sessionIdentity(of: target)
        let connectCall = Task { () -> Result<[String?], Error> in
            do {
                return .success(try await target.executeDirect(
                    OracleDebugStatements.jdwpConnect,
                    binds: [.text(launch.debuggerHost), .text(String(port))]
                ))
            } catch {
                return .failure(error)
            }
        }
        // A refused CONNECT_TCP ends the wait at once; one that hangs on an unreachable host is cut at the timeout.
        let watcher = Task {
            if case .failure = await connectCall.value { listener.cancel() }
        }
        defer { watcher.cancel() }
        let connection: OracleJDWPConnection
        do {
            connection = try await listener.accept(timeout: launch.connectTimeout)
        } catch {
            listener.cancel()
            let rejected = listener.rejectedPeers
            if let result = await OracleDebugSupport.value(of: connectCall, within: 1), case .failure(let error) = result {
                if Task.isCancelled { throw CancellationError() }
                let reason = rejected.isEmpty
                    ? OracleDebugStatements.jdwpFailure(fromMessage: message(of: error))
                    : .unexpectedPeer(rejected)
                throw JDWPStartFailure(reason: reason, port: port)
            }
            // The statement is still waiting on the network; closing the channel is the only way to end it.
            target.cancelCurrentQuery()
            _ = await OracleDebugSupport.value(of: connectCall, within: 5)
            if Task.isCancelled { throw CancellationError() }
            throw JDWPStartFailure(reason: rejected.isEmpty ? .timedOut : .unexpectedPeer(rejected), port: port, endedTarget: true)
        }
        let session = OracleJDWPDebugSession(
            connection: connection,
            target: target,
            helper: helper,
            entryPoint: launch.entryPoint,
            invocation: invocation,
            connectCall: connectCall,
            targetIdentity: identity,
            notices: [.connectedOverJDWP(host: launch.debuggerHost, port: Int(port))]
        )
        do {
            try await session.start(breakpoints: breakpoints)
        } catch {
            // Closing the JDWP socket ends the target session.
            _ = await session.stop()
            if Task.isCancelled { throw CancellationError() }
            if let failure = error as? OracleDebugError {
                switch failure {
                case .jdwp(let reason):
                    throw JDWPStartFailure(reason: reason, port: port, endedTarget: true)
                case .malformedReply, .debuggerStoppedAnswering, .ended:
                    throw JDWPStartFailure(reason: .handshakeFailed, port: port, endedTarget: true)
                default:
                    break
                }
            }
            throw JDWPStartFailure(reason: .other(message(of: error)), port: port, endedTarget: true)
        }
        return session
    }

    static func message(of error: Error) -> String {
        OracleDebugSupport.message(of: error)
    }

    // ORA-01031 from INITIALIZE or CONNECT_TCP is the missing DEBUG CONNECT SESSION (measured).
    static func mapped(_ error: Error) -> Error {
        guard let core = error as? OracleCoreError, case .queryFailed(let message) = core else { return error }
        let codes = OracleDebugStatements.errorCodes(in: message)
        if codes.first == 1_031 {
            return OracleDebugError.privilegeMissing(message)
        }
        return OracleDebugError.server(code: codes.first, message: message)
    }
}
