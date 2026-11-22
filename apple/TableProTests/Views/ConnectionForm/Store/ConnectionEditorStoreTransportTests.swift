//
//  ConnectionEditorStoreTransportTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro
import TableProTestSupport

@MainActor
struct ConnectionEditorStoreTransportTests {
    private func passTest(_ store: ConnectionEditorStore) -> ConnectionTestState {
        store.lastTestedFingerprint = ConnectionEditorEngine.testFingerprint(
            store.draft, store.traits, originalTraits: store.originalTraits, store.context
        )
        let state = ConnectionTestState.succeeded(
            ConnectionTestSuccess(typeName: store.traits.displayName, serverVersion: nil, elapsedMilliseconds: 12, warning: nil)
        )
        store.testState = state
        return state
    }

    private func makeStore(_ fixture: ConnectionEditorStoreFixture, download: CloudSQLProxyDownload) -> ConnectionEditorStore {
        ConnectionEditorStore(
            request: .new(type: .postgresql, parsedURL: nil),
            services: fixture.services,
            recentConnections: fixture.recents,
            listPreferences: fixture.listPreferences,
            cloudSQLProxyDownload: download
        )
    }

    // MARK: - Test result

    @Test("Selecting a transport clears a passing test result")
    func selectionInvalidatesTestResult() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .mysql, parsedURL: nil))
        let passed = passTest(store)
        #expect(store.testState == passed)

        store.selectTransport(.ssh)

        #expect(store.testState == .idle)
    }

    @Test("Choosing an endpoint clears a passing test result")
    func endpointInvalidatesTestResult() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .mysql, parsedURL: nil))
        _ = passTest(store)

        store.selectEndpoint(.localSocket)

        #expect(store.testState == .idle)
    }

    // MARK: - Host list over a tunnel

    @Test("Redis Cluster and Kafka advice never speaks of a replica set")
    func clusterAndBrokerAdviceIsNotAboutReplicaSets() throws {
        let cluster = try #require(TunnelHostListAdvice.message(fieldId: "redisClusterHosts", hosts: "n1.example:7000,n2.example:7001"))
        #expect(!cluster.localizedCaseInsensitiveContains("replica set"))
        let kafka = try #require(TunnelHostListAdvice.message(fieldId: "kafkaBootstrapServers", hosts: "b1.example:9092,b2.example:9092"))
        #expect(!kafka.localizedCaseInsensitiveContains("replica set"))
    }

    // MARK: - Tunnel command preview

    @Test("A cleared Port previews the engine's default port, which is what connects")
    func clearedPortPreviewsDefaultPort() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.selectTransport(.tunnelCommand)
        store.update {
            $0.tunnelCommand.config.method = .kubectl
            $0.tunnelCommand.config.kubernetesResource = "service/postgres"
        }
        store.setPort("")

        let preview = try #require(store.tunnelCommandPreview)

        #expect(preview.contains("{port}:5432"))
        #expect(!preview.contains(":0"))
    }

    @Test("A host-list connection previews the first listed node, which is what connects")
    func hostListPreviewsFirstListedNode() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .redis, parsedURL: nil))
        store.selectTransport(.tunnelCommand)
        store.update { $0.host = "" }
        store.setFieldValue("cluster", for: "redisMode")
        store.setFieldValue("a.example:7000,b.example:7001", for: "redisClusterHosts")
        store.update {
            $0.tunnelCommand.config.method = .custom
            $0.tunnelCommand.config.command = "forward {port} {host}:{remotePort}"
        }

        let preview = try #require(store.tunnelCommandPreview)

        #expect(preview == "forward '{port}' a.example:7000")
    }

    // MARK: - Cloud SQL Auth Proxy binary

    @Test("The editor shows the shared download, and its Cancel stops it")
    func editorFollowsSharedDownload() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = DownloadRecord()
        let download = CloudSQLProxyDownload(binaryManager: CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(Data("pinned build".utf8)),
            download: { _, progress in
                record.started()
                await progress(0.5)
                await suspendUntilCancelled()
                record.sawCancel()
                throw URLError(.cancelled)
            }
        ))
        let store = makeStore(fixture, download: download)

        store.downloadCloudSQLProxy()
        try await waitUntil { store.cloudSQLProxyDownloadPhase == .downloading(fraction: 0.5) }
        #expect(store.cloudSQLProxyDownloadPhase.isDownloading)

        store.cancelCloudSQLProxyDownload()
        #expect(store.cloudSQLProxyDownloadPhase == .idle)
        try await waitUntil { record.wasCancelled }
    }

    @Test(
        "Only a managed binary that passes its checksum shows as detected",
        .enabled(if: CLIExecutableFinder.findExecutable("cloud-sql-proxy") == nil, "a system cloud-sql-proxy wins over the managed one")
    )
    func detectedNeedsACurrentManagedBinary() async throws {
        let fixture = try ConnectionEditorStoreFixture()
        let dir = try TestProxyDownload.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = Data("pinned build".utf8)
        let binary = dir.appendingPathComponent("cloud-sql-proxy")
        try Data("altered".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try CloudSQLProxyBinaryManager.pinnedVersion
            .write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8)
        let store = makeStore(fixture, download: CloudSQLProxyDownload(binaryManager: CloudSQLProxyBinaryManager(
            baseDirectory: dir,
            expectedSHA256: TestProxyDownload.pins(bytes),
            download: TestProxyDownload.serving(bytes, into: dir)
        )))

        store.detectCloudSQLProxy()
        try await waitUntil { store.cloudSQLProxyDetection != .checking }
        #expect(store.cloudSQLProxyDetection == .notFound)

        try bytes.write(to: binary)
        store.detectCloudSQLProxy()
        try await waitUntil { store.cloudSQLProxyDetection != .checking }
        #expect(store.cloudSQLProxyDetection == .found(binary.path))
    }

    // MARK: - Cloudflare browser sign-in

    @Test("Browser sign-in refuses a hostname cloudflared would read as an option or split", arguments: [
        "-h", "--help", "db.example.com --url x", "db\texample.com", "db.example.com\u{202E}",
    ])
    func signInRefusesFlagLikeHostname(hostname: String) throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.cloudflare.binaryPath = "/usr/bin/true"
            $0.cloudflare.accessHostname = hostname
        }

        store.signInWithCloudflare()

        #expect(store.cloudflareSignInError != nil)
    }

    @Test("Browser sign-in starts for a plain hostname")
    func signInStartsForPlainHostname() throws {
        let fixture = try ConnectionEditorStoreFixture()
        let store = fixture.makeStore(.new(type: .postgresql, parsedURL: nil))
        store.update {
            $0.cloudflare.binaryPath = "/usr/bin/true"
            $0.cloudflare.accessHostname = "db.example.com"
        }

        store.signInWithCloudflare()

        #expect(store.cloudflareSignInError == nil)
    }
}
