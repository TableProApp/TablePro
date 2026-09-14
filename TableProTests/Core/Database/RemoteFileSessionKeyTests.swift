//
//  RemoteFileSessionKeyTests.swift
//  TableProTests
//

import Testing

@testable import TablePro

/// The cached SFTP session is reused only when the server it was opened against still matches, so a
/// connection edited to point at a different host does not download the old server's file.
struct RemoteFileSessionKeyTests {
    private func config(host: String, port: Int? = 22, username: String = "deploy", path: String) -> SSHConfiguration {
        var config = SSHConfiguration()
        config.enabled = true
        config.host = host
        config.port = port
        config.username = username
        config.remoteFilePath = path
        return config
    }

    @Test("Two configurations differing only in the file path share a session key")
    func pathDoesNotChangeTheKey() {
        let a = config(host: "prod-1", path: "/srv/app.db")
        let b = config(host: "prod-1", path: "/srv/other.db")
        #expect(RemoteFileTransportManager.serverKey(a) == RemoteFileTransportManager.serverKey(b))
    }

    @Test("The access mode does not change the session key")
    func accessModeDoesNotChangeTheKey() {
        var a = config(host: "prod-1", path: "/srv/app.db")
        var b = a
        a.remoteFileAccess = .onServer
        b.remoteFileAccess = .readOnlyCopy
        #expect(RemoteFileTransportManager.serverKey(a) == RemoteFileTransportManager.serverKey(b))
    }

    @Test("A different host produces a different session key")
    func hostChangesTheKey() {
        let a = config(host: "prod-1", path: "/srv/app.db")
        let b = config(host: "prod-2", path: "/srv/app.db")
        #expect(RemoteFileTransportManager.serverKey(a) != RemoteFileTransportManager.serverKey(b))
    }

    @Test("A different port or user produces a different session key")
    func portAndUserChangeTheKey() {
        let base = RemoteFileTransportManager.serverKey(config(host: "prod-1", path: "/srv/app.db"))
        let otherPort = RemoteFileTransportManager.serverKey(config(host: "prod-1", port: 2_222, path: "/srv/app.db"))
        let otherUser = RemoteFileTransportManager.serverKey(config(host: "prod-1", username: "root", path: "/srv/app.db"))
        #expect(base != otherPort)
        #expect(base != otherUser)
    }
}
