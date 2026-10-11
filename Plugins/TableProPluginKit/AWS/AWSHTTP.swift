import Foundation

public enum AWSHTTP {
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 30

    public static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }()

    /// Connect-only credential sessions carry one monotonic deadline in their description. Keeping
    /// this as private session metadata lets bundled drivers bound SSO, STS and credential_process
    /// without adding a symbol to TableProPluginKit's public ABI.
    static let connectDeadlineSessionDescriptionPrefix = "com.tablepro.aws-connect-deadline-v1:"

    static func connectDeadline(for session: URLSession) -> AWSConnectDeadline? {
        guard let description = session.sessionDescription,
              description.hasPrefix(connectDeadlineSessionDescriptionPrefix),
              let expiresAtUptime = TimeInterval(description.dropFirst(connectDeadlineSessionDescriptionPrefix.count)),
              expiresAtUptime.isFinite
        else {
            return nil
        }
        return AWSConnectDeadline(expiresAtUptime: expiresAtUptime)
    }

    static func applyConnectDeadline(
        to request: inout URLRequest,
        session: URLSession,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) throws {
        guard let deadline = connectDeadline(for: session) else { return }
        guard let remaining = deadline.remainingSeconds(at: now) else {
            throw URLError(.timedOut)
        }
        request.timeoutInterval = remaining
    }
}

struct AWSConnectDeadline: Equatable, Sendable {
    let expiresAtUptime: TimeInterval

    func remainingSeconds(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval? {
        let remaining = expiresAtUptime - now
        guard remaining > 0 else { return nil }
        return max(remaining, 0.001)
    }
}
