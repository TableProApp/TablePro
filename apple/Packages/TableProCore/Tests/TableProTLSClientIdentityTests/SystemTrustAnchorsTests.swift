#if os(macOS)
import Foundation
import Security
import TableProTestSupport
import TableProTLSClientIdentity
import TableProTLSTestFixtures
import Testing

private final class FixtureTrustSource: SystemTrustSource {
    struct Entry {
        let certificate: SecCertificate
        let settings: [SystemTrustSetting]?
        var unreadable = false
    }

    var domains: [SystemTrustDomain: [Entry]] = [:]
    var unreadableDomains: Set<SystemTrustDomain> = []
    var anchors: [SecCertificate] = []
    private(set) var userDomainReads = 0

    func add(_ certificate: SecCertificate, to domain: SystemTrustDomain, _ settings: [SystemTrustSetting]?) {
        domains[domain, default: []].append(Entry(certificate: certificate, settings: settings))
    }

    func certificates(in domain: SystemTrustDomain) throws -> [SecCertificate] {
        if domain == .user { userDomainReads += 1 }
        guard !unreadableDomains.contains(domain) else { throw SystemTrustAnchorsError.settingsUnreadable(-1) }
        return domains[domain, default: []].map(\.certificate)
    }

    func settings(for certificate: SecCertificate, in domain: SystemTrustDomain) throws -> [SystemTrustSetting]? {
        let der = SecCertificateCopyData(certificate) as Data
        guard let entry = domains[domain, default: []].first(where: { SecCertificateCopyData($0.certificate) as Data == der })
        else { return nil }
        guard !entry.unreadable else { throw SystemTrustAnchorsError.settingsUnreadable(-1) }
        return entry.settings
    }

    func anchorCertificates() throws -> [SecCertificate] {
        anchors
    }
}

struct SystemTrustAnchorsTests {
    private let rootA: SecCertificate
    private let rootB: SecCertificate

    init() throws {
        rootA = try #require(SecCertificateCreateWithData(nil, TLSTestFixtures.der(TLSTestFixtures.caCertificate) as CFData))
        rootB = try #require(
            SecCertificateCreateWithData(nil, TLSTestFixtures.der(TLSTestFixtures.serverNameCACertificate) as CFData)
        )
    }

    private func ders(_ certificates: [SecCertificate]) -> Set<Data> {
        Set(certificates.map { SecCertificateCopyData($0) as Data })
    }

    private func exported(_ source: FixtureTrustSource) throws -> Set<Data> {
        ders(try SystemTrustAnchors.trustedRoots(from: source))
    }

    @Test("A certificate whose trust settings are empty is trusted as a root")
    func emptySettingsTrustTheRoot() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])

        #expect(try exported(source) == ders([rootA]))
    }

    @Test("A user Deny removes a root the system trusts")
    func aUserDenyRemovesASystemRoot() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootB, to: .system, [])
        source.add(rootA, to: .user, [SystemTrustSetting(result: .deny)])

        #expect(try exported(source) == ders([rootB]))
    }

    @Test("A root trusted in the admin domain joins the system roots")
    func anAdminTrustAddsARoot() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootB, to: .admin, [SystemTrustSetting(result: .trustRoot)])

        #expect(try exported(source) == ders([rootA, rootB]))
    }

    @Test("User settings override admin settings in both directions")
    func userSettingsOverrideAdminSettings() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .admin, [SystemTrustSetting(result: .deny)])
        source.add(rootA, to: .user, [SystemTrustSetting(result: .trustRoot)])
        source.add(rootB, to: .admin, [SystemTrustSetting(result: .trustRoot)])
        source.add(rootB, to: .user, [SystemTrustSetting(result: .deny)])

        #expect(try exported(source) == ders([rootA]))
    }

    @Test("A setting for another policy or for one application does not apply")
    func anEntryForAnotherPolicyDoesNotApply() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootA, to: .user, [SystemTrustSetting(appliesToSSL: false, result: .deny)])
        source.add(rootB, to: .user, [SystemTrustSetting(namesApplication: true, result: .trustRoot)])

        #expect(try exported(source) == ders([rootA]))
    }

    @Test("A trust limited to one hostname is left out, because a PEM file cannot carry the limit")
    func aHostnameScopedTrustIsNotExported() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootB, to: .user, [SystemTrustSetting(hostname: "db.example.com", result: .trustRoot)])

        #expect(try exported(source) == ders([rootA]))
    }

    @Test("A Deny limited to one hostname removes the root for every host")
    func aHostnameScopedDenyRemovesTheRoot() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootA, to: .user, [
            SystemTrustSetting(hostname: "db.example.com", result: .deny),
            SystemTrustSetting(result: .trustRoot)
        ])

        #expect(try exported(source).isEmpty)
    }

    @Test("Unspecified moves on to the next entry, then to the next domain")
    func unspecifiedFallsThroughToTheNextDomain() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootA, to: .user, [SystemTrustSetting(result: .unspecified)])
        source.add(rootB, to: .user, [SystemTrustSetting(result: .unspecified)])

        #expect(try exported(source) == ders([rootA]))

        source.add(rootB, to: .admin, [SystemTrustSetting(result: .unspecified), SystemTrustSetting()])
        #expect(try exported(source) == ders([rootA, rootB]))
    }

    @Test("A settings array the domain cannot read counts as a Deny")
    func unreadableSettingsFailClosed() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.domains[.user] = [FixtureTrustSource.Entry(certificate: rootA, settings: [], unreadable: true)]

        #expect(try exported(source).isEmpty)
    }

    @Test("A user or admin domain that cannot be read fails the build")
    func anUnreadableUserDomainIsAnError() {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.unreadableDomains = [.admin]

        #expect(throws: SystemTrustAnchorsError.settingsUnreadable(-1)) {
            try SystemTrustAnchors.trustedRoots(from: source)
        }
    }

    @Test("The system anchors stand in when the system domain cannot be read, and a user Deny still wins")
    func theSystemAnchorsAreTheFallback() throws {
        let source = FixtureTrustSource()
        source.unreadableDomains = [.system]
        source.anchors = [rootA, rootB]
        source.add(rootB, to: .user, [SystemTrustSetting(result: .deny)])

        #expect(try exported(source) == ders([rootA]))

        source.unreadableDomains = []
        #expect(try exported(source) == ders([rootA]))
    }

    @Test("No trusted root is an error, never an empty file")
    func noAnchorsIsAnError() {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [SystemTrustSetting(result: .deny)])

        #expect(throws: SystemTrustAnchorsError.noTrustedRoots) {
            try SystemTrustAnchors.pem(from: source)
        }
    }

    @Test("The PEM holds one block per trusted root")
    func thePEMHoldsEveryRoot() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        source.add(rootB, to: .system, [])

        let pem = try #require(String(bytes: SystemTrustAnchors.pem(from: source), encoding: .utf8))

        #expect(pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").count == 3)
    }

    @Test("This Mac's own trust settings export as PEM")
    func theRealStoreExportsPEM() throws {
        let source = SecuritySystemTrustSource()

        let roots = try SystemTrustAnchors.trustedRoots(from: source)
        let pem = try #require(String(bytes: SystemTrustAnchors.pem(from: source), encoding: .utf8))

        #expect(!roots.isEmpty)
        #expect(pem.hasPrefix("-----BEGIN CERTIFICATE-----"))
    }

    @Test("A trust settings entry is read for its policy, hostname, application and result")
    func readsATrustSettingsEntry() {
        let scoped = SecuritySystemTrustSource.setting(from: [
            kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
            kSecTrustSettingsPolicyString as String: "db.example.com",
            kSecTrustSettingsResult as String: NSNumber(value: 3)
        ])
        #expect(scoped == SystemTrustSetting(hostname: "db.example.com", result: .deny))

        let otherPolicy = SecuritySystemTrustSource.setting(from: [kSecTrustSettingsPolicy as String: SecPolicyCreateBasicX509()])
        #expect(otherPolicy == SystemTrustSetting(appliesToSSL: false))

        let application = SecuritySystemTrustSource.setting(from: [kSecTrustSettingsApplication as String: "app"])
        #expect(application == SystemTrustSetting(namesApplication: true))
    }

    @Test("A result value Apple does not define counts as a Deny", arguments: [0, 9])
    func anUnknownResultCountsAsADeny(value: Int) {
        let setting = SecuritySystemTrustSource.setting(from: [kSecTrustSettingsResult as String: NSNumber(value: value)])
        #expect(setting.result == .deny)
    }

    @Test("The bytes are reused for a minute, then rebuilt, and a failed build is not kept")
    func theCacheRebuildsAfterAMinute() throws {
        let source = FixtureTrustSource()
        let clock = ManualClock()
        let cache = SystemTrustAnchorCache(source: source, clock: clock)

        #expect(throws: SystemTrustAnchorsError.noTrustedRoots) { try cache.pem() }
        source.add(rootA, to: .system, [])
        let first = try cache.pem()
        #expect(source.userDomainReads == 2)

        clock.advance(by: .seconds(59))
        #expect(try cache.pem() == first)
        #expect(source.userDomainReads == 2)

        clock.advance(by: .seconds(1))
        _ = try cache.pem()
        #expect(source.userDomainReads == 3)
    }

    @Test("Each use gets its own owner-only file in an owner-only folder, removed with its folder")
    func aWrittenFileIsOwnerOnly() throws {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        let cache = SystemTrustAnchorCache(source: source, clock: ManualClock())
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("trust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }

        let file = try cache.writeFile(in: parent)
        let other = try cache.writeFile(in: parent)
        let folder = file.url.deletingLastPathComponent()

        #expect(file.url != other.url)
        #expect(try Data(contentsOf: file.url) == cache.pem())
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        #expect(folderMode?.int16Value == 0o700)
        #expect(fileMode?.int16Value == 0o600)

        file.remove()
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: other.url.path))
    }

    @Test("A file that cannot be written is an error and leaves nothing behind")
    func anUnwritableFolderIsAnError() {
        let source = FixtureTrustSource()
        source.add(rootA, to: .system, [])
        let cache = SystemTrustAnchorCache(source: source, clock: ManualClock())
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")

        #expect(throws: SystemTrustAnchorsError.fileUnwritable) { try cache.writeFile(in: missing) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }
}
#endif
