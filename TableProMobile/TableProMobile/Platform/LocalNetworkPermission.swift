import Foundation
import Network
import os

enum LocalNetworkPermissionError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "Local Network access is required. Open Settings > Privacy & Security > Local Network and turn TablePro on.")
    }
}

actor LocalNetworkPermission {
    static let shared = LocalNetworkPermission()

    private static let logger = Logger(subsystem: "com.TablePro", category: "LocalNetworkPermission")
    private static let promptTimeout: Duration = .seconds(5)
    private static let triggerServiceType = "_ssh._tcp"

    enum Resolution: Sendable {
        case unknown
        case granted
        case unavailable
    }

    private var resolution: Resolution = .unknown
    private var inFlight: Task<Resolution, Never>?

    func ensureAccess(for host: String) async throws {
        guard Self.isLocalNetworkHost(host) else { return }

        switch resolution {
        case .granted:
            return
        case .unavailable:
            throw LocalNetworkPermissionError.unavailable
        case .unknown:
            let result = await resolve()
            if case .unavailable = result {
                throw LocalNetworkPermissionError.unavailable
            }
        }
    }

    private func resolve() async -> Resolution {
        if let inFlight {
            return await inFlight.value
        }

        let task = Task<Resolution, Never> {
            await Self.runPrompt()
        }
        inFlight = task

        let result = await task.value
        resolution = result
        inFlight = nil
        return result
    }

    private static func runPrompt() async -> Resolution {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: triggerServiceType, domain: nil),
            using: NWParameters()
        )
        let (stream, continuation) = AsyncStream<NWBrowser.State>.makeStream()

        browser.stateUpdateHandler = { state in
            logger.info("NWBrowser state: \(String(describing: state), privacy: .public)")
            continuation.yield(state)
            switch state {
            case .ready, .failed, .cancelled, .waiting:
                continuation.finish()
            default:
                break
            }
        }

        browser.start(queue: .global(qos: .userInitiated))

        let timeoutTask = Task {
            try? await Task.sleep(for: promptTimeout)
            continuation.finish()
        }

        var resolved: Resolution = .unknown
        for await state in stream {
            switch state {
            case .ready:
                resolved = .granted
            case .waiting, .failed:
                resolved = .unavailable
            case .cancelled:
                break
            default:
                continue
            }
        }

        timeoutTask.cancel()
        browser.cancel()
        return resolved
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        if lowered.hasSuffix(".local") { return true }
        if lowered == "localhost" { return false }

        if let bytes = IPv4Address(host)?.rawValue, bytes.count == 4 {
            let octets = Array(bytes)
            if octets[0] == 10 { return true }
            if octets[0] == 172, (16...31).contains(octets[1]) { return true }
            if octets[0] == 192, octets[1] == 168 { return true }
            if octets[0] == 169, octets[1] == 254 { return true }
            return false
        }

        if let bytes = IPv6Address(host)?.rawValue, !bytes.isEmpty {
            let octets = Array(bytes)
            if (octets[0] & 0xfe) == 0xfc { return true }
            if octets.count >= 2, octets[0] == 0xfe, (octets[1] & 0xc0) == 0x80 { return true }
            return false
        }

        return false
    }
}
