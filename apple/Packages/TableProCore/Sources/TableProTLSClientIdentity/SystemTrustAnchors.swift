#if os(macOS)
import Foundation
import os
import Security

public enum SystemTrustDomain: Sendable {
    case user
    case admin
    case system

    var securityDomain: SecTrustSettingsDomain {
        switch self {
        case .user: .user
        case .admin: .admin
        case .system: .system
        }
    }
}

public enum SystemTrustResult: Sendable, Equatable {
    case trustRoot
    case trustAsRoot
    case deny
    case unspecified
}

public struct SystemTrustSetting: Sendable, Equatable {
    public var appliesToSSL: Bool
    public var namesApplication: Bool
    public var hostname: String?
    // Nil when the entry carries no result, which Apple reads as TrustRoot.
    public var result: SystemTrustResult?

    public init(
        appliesToSSL: Bool = true,
        namesApplication: Bool = false,
        hostname: String? = nil,
        result: SystemTrustResult? = nil
    ) {
        self.appliesToSSL = appliesToSSL
        self.namesApplication = namesApplication
        self.hostname = hostname
        self.result = result
    }
}

public protocol SystemTrustSource {
    // Empty when the domain has no trust settings.
    func certificates(in domain: SystemTrustDomain) throws -> [SecCertificate]
    // Nil when the domain holds no settings for the certificate.
    func settings(for certificate: SecCertificate, in domain: SystemTrustDomain) throws -> [SystemTrustSetting]?
    func anchorCertificates() throws -> [SecCertificate]
}

public enum SystemTrustAnchorsError: Error, Sendable, Equatable {
    case settingsUnreadable(OSStatus)
    case noTrustedRoots
    case exportFailed(OSStatus)
    case fileUnwritable
}

extension SystemTrustAnchorsError: LocalizedError {
    public var message: String {
        String(
            localized: """
                Could not read this Mac's trusted certificates to verify the server. Choose the server's CA \
                certificate under SSL, then connect again.
                """
        )
    }

    public var errorDescription: String? {
        message
    }
}

// For a TLS library with no trust store of its own, such as the bundled OpenSSL. The roots come from the trust
// settings, never from evaluating each root alone: a SHA-1 self-signed root fails as a leaf and still anchors chains.
public enum SystemTrustAnchors {
    public static let shared = SystemTrustAnchorCache(source: SecuritySystemTrustSource(), clock: ContinuousClock())

    static let logger = Logger(subsystem: "com.TablePro", category: "SystemTrustAnchors")

    // Per-user settings override admin ones, which override the system's. The first domain with a result decides.
    public static func trustedRoots(from source: any SystemTrustSource) throws -> [SecCertificate] {
        var results: [Data: SystemTrustResult] = [:]
        var decided: [(der: Data, certificate: SecCertificate)] = []
        for domain in [SystemTrustDomain.user, .admin, .system] {
            let (certificates, fromAnchorList) = try certificates(in: domain, from: source)
            for certificate in certificates {
                let der = SecCertificateCopyData(certificate) as Data
                guard results[der] == nil else { continue }
                let result: SystemTrustResult? = fromAnchorList ? .trustRoot : decision(for: certificate, in: domain, from: source)
                guard let result else { continue }
                results[der] = result
                decided.append((der, certificate))
            }
        }
        return decided.filter { results[$0.der] == .trustRoot || results[$0.der] == .trustAsRoot }.map(\.certificate)
    }

    public static func pem(from source: any SystemTrustSource) throws -> Data {
        let roots = try trustedRoots(from: source)
        guard !roots.isEmpty else { throw SystemTrustAnchorsError.noTrustedRoots }
        var exported: CFData?
        let status = SecItemExport(roots as CFArray, .formatPEMSequence, [], nil, &exported)
        guard status == errSecSuccess, let exported, CFDataGetLength(exported) > 0 else {
            logger.error("Exporting the trusted roots failed: \(status, privacy: .public)")
            throw SystemTrustAnchorsError.exportFailed(status)
        }
        return exported as Data
    }

    static func effectiveResult(of settings: [SystemTrustSetting]) -> SystemTrustResult? {
        guard !settings.isEmpty else { return .trustRoot }
        for setting in settings where setting.appliesToSSL && !setting.namesApplication {
            let result = setting.result ?? .trustRoot
            // A PEM cannot carry a hostname limit, so a scoped trust is left out and a scoped deny covers every host.
            if setting.hostname != nil {
                if result == .deny { return .deny }
                continue
            }
            if result != .unspecified { return result }
        }
        return nil
    }

    // The system domain is the one that must answer. If it cannot, the anchors macOS ships stand in for it.
    private static func certificates(
        in domain: SystemTrustDomain,
        from source: any SystemTrustSource
    ) throws -> (certificates: [SecCertificate], fromAnchorList: Bool) {
        do {
            let certificates = try source.certificates(in: domain)
            if domain == .system, certificates.isEmpty {
                logger.error("The system trust settings list no certificates; using the system anchors")
                return (try source.anchorCertificates(), true)
            }
            return (certificates, false)
        } catch {
            logger.error(
                "Reading the \(String(describing: domain), privacy: .public) trust settings failed: \(String(describing: error), privacy: .private)"
            )
            guard domain == .system else { throw error }
            return (try source.anchorCertificates(), true)
        }
    }

    // A setting that cannot be read could be a deny, so it counts as one.
    private static func decision(
        for certificate: SecCertificate,
        in domain: SystemTrustDomain,
        from source: any SystemTrustSource
    ) -> SystemTrustResult? {
        do {
            guard let settings = try source.settings(for: certificate, in: domain) else { return nil }
            return effectiveResult(of: settings)
        } catch {
            logger.error("A certificate's \(String(describing: domain), privacy: .public) trust settings could not be read")
            return .deny
        }
    }
}

// The bytes are kept for a minute, so a root just trusted or distrusted in Keychain Access applies on a later connect
// without a relaunch. A failed build is never kept.
public final class SystemTrustAnchorCache<C: Clock>: @unchecked Sendable where C.Duration == Duration {
    private let source: any SystemTrustSource
    private let clock: C
    private let lifetime: Duration
    private let lock = NSLock()
    private var cached: (pem: Data, builtAt: C.Instant)?

    public init(source: any SystemTrustSource, clock: C, lifetime: Duration = .seconds(60)) {
        self.source = source
        self.clock = clock
        self.lifetime = lifetime
    }

    public func pem() throws -> Data {
        try lock.withLock {
            if let cached, cached.builtAt.duration(to: clock.now) < lifetime {
                return cached.pem
            }
            let built = try SystemTrustAnchors.pem(from: source)
            cached = (built, clock.now)
            return built
        }
    }

    public func writeFile(in parent: URL = FileManager.default.temporaryDirectory) throws -> SystemTrustAnchorFile {
        try SystemTrustAnchorFile.write(pem(), in: parent)
    }
}

// One file per use, in a folder only this user can open, removed when the use ends.
public struct SystemTrustAnchorFile: Sendable {
    public let url: URL
    let directory: URL

    static func write(_ pem: Data, in parent: URL) throws -> SystemTrustAnchorFile {
        let directory = parent.appendingPathComponent("tablepro-trust-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("roots.pem")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: pem,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw SystemTrustAnchorsError.fileUnwritable
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            SystemTrustAnchors.logger.error("Writing the trusted roots file failed")
            throw SystemTrustAnchorsError.fileUnwritable
        }
        return SystemTrustAnchorFile(url: url, directory: directory)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

public struct SecuritySystemTrustSource: SystemTrustSource, Sendable {
    public init() {}

    public func certificates(in domain: SystemTrustDomain) throws -> [SecCertificate] {
        var certificates: CFArray?
        let status = SecTrustSettingsCopyCertificates(domain.securityDomain, &certificates)
        if status == errSecNoTrustSettings { return [] }
        guard status == errSecSuccess else { throw SystemTrustAnchorsError.settingsUnreadable(status) }
        return (certificates as? [SecCertificate]) ?? []
    }

    public func settings(for certificate: SecCertificate, in domain: SystemTrustDomain) throws -> [SystemTrustSetting]? {
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, domain.securityDomain, &settings)
        if status == errSecItemNotFound || status == errSecNoTrustSettings { return nil }
        guard status == errSecSuccess else { throw SystemTrustAnchorsError.settingsUnreadable(status) }
        let entries = (settings as? [[String: Any]]) ?? []
        return entries.map(Self.setting(from:))
    }

    public func anchorCertificates() throws -> [SecCertificate] {
        var anchors: CFArray?
        let status = SecTrustCopyAnchorCertificates(&anchors)
        guard status == errSecSuccess else { throw SystemTrustAnchorsError.settingsUnreadable(status) }
        return (anchors as? [SecCertificate]) ?? []
    }

    public static func setting(from entry: [String: Any]) -> SystemTrustSetting {
        let hostname = entry[kSecTrustSettingsPolicyString as String] as? String
        return SystemTrustSetting(
            appliesToSSL: entry[kSecTrustSettingsPolicy as String].map(isSSLPolicy) ?? true,
            namesApplication: entry[kSecTrustSettingsApplication as String] != nil,
            hostname: hostname?.isEmpty == false ? hostname : nil,
            result: (entry[kSecTrustSettingsResult as String] as? NSNumber).map { result(of: $0.uint32Value) }
        )
    }

    private static func isSSLPolicy(_ value: Any) -> Bool {
        guard CFGetTypeID(value as CFTypeRef) == SecPolicyGetTypeID() else { return false }
        let policy = unsafeDowncast(value as AnyObject, to: SecPolicy.self)
        let properties = SecPolicyCopyProperties(policy) as? [String: Any]
        return properties?[kSecPolicyOid as String] as? String == kSecPolicyAppleSSL as String
    }

    // An unknown value could mean distrust, so it counts as a deny.
    private static func result(of rawValue: UInt32) -> SystemTrustResult {
        switch SecTrustSettingsResult(rawValue: rawValue) {
        case .trustRoot?: .trustRoot
        case .trustAsRoot?: .trustAsRoot
        case .unspecified?: .unspecified
        default: .deny
        }
    }
}
#endif
