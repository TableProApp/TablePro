//
//  LibPQConnectionStringTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("LibPQConnectionString")
struct LibPQConnectionStringTests {
    private func build(
        user: String = "postgres",
        password: String? = "hunter2",
        sslConfig: SSLConfiguration = SSLConfiguration(),
        options: String? = nil
    ) -> String {
        LibPQConnectionString.build(
            host: "db.example.com",
            port: 5_432,
            user: user,
            password: password,
            database: "app",
            sslConfig: sslConfig,
            options: options
        )
    }

    @Test("The base parameters are always present")
    func baseParameters() {
        let conninfo = build()

        #expect(conninfo.contains("host='db.example.com'"))
        #expect(conninfo.contains("port='5432'"))
        #expect(conninfo.contains("dbname='app'"))
        #expect(conninfo.contains("user='postgres'"))
        #expect(conninfo.contains("password='hunter2'"))
        #expect(conninfo.contains("sslmode='disable'"))
    }

    @Test("The session is pinned to UTF8 in the startup packet, so RESET ALL and DISCARD ALL keep it")
    func pinsClientEncoding() {
        #expect(build().contains("client_encoding='UTF8'"))
    }

    @Test("Connection options still reach the server, after the pinned encoding")
    func optionsFollowTheEncoding() {
        let conninfo = build(options: "--cluster=my-cluster -c search_path=app")

        #expect(conninfo.hasSuffix("client_encoding='UTF8' options='--cluster=my-cluster -c search_path=app'"))
    }

    @Test("A client_encoding in the connection options rides along in options, where the server applies it first")
    func clientEncodingInOptionsStaysInOptions() {
        let conninfo = build(options: "-c client_encoding=LATIN1")

        #expect(conninfo.contains("client_encoding='UTF8'"))
        #expect(conninfo.contains("options='-c client_encoding=LATIN1'"))
    }

    @Test("An empty user, password or options is left out")
    func emptyValuesAreOmitted() {
        let conninfo = build(user: "", password: "", options: "")

        #expect(!conninfo.contains("user="))
        #expect(!conninfo.contains("password="))
        #expect(!conninfo.contains("options="))
        #expect(conninfo.contains("client_encoding='UTF8'"))
    }

    @Test("A CA certificate is sent only when the mode verifies it")
    func caOnlyWhenVerifying() {
        let requiring = build(sslConfig: SSLConfiguration(mode: .required, caCertificatePath: "/ca.pem"))
        #expect(!requiring.contains("sslrootcert"))

        let verifying = build(sslConfig: SSLConfiguration(mode: .verifyCa, caCertificatePath: "/ca.pem"))
        #expect(verifying.contains("sslmode='verify-ca'"))
        #expect(verifying.contains("sslrootcert='/ca.pem'"))
    }

    @Test("A client certificate and key reach libpq as sslcert and sslkey")
    func clientCertificateIsSent() {
        let conninfo = build(sslConfig: SSLConfiguration(
            mode: .required,
            clientCertificatePath: "/client.pem",
            clientKeyPath: "/client.key"
        ))

        #expect(conninfo.contains("sslcert='/client.pem'"))
        #expect(conninfo.contains("sslkey='/client.key'"))
    }

    @Test("Quotes and backslashes in values are escaped")
    func escapesValues() {
        let conninfo = build(user: "o'brien", password: "back\\slash", options: "-c application_name='x'")

        #expect(conninfo.contains("user='o\\'brien'"))
        #expect(conninfo.contains("password='back\\\\slash'"))
        #expect(conninfo.contains("options='-c application_name=\\'x\\''"))
    }

    @Test("UTF8 and its PostgreSQL 8.0 name UNICODE both count as the pinned encoding")
    func recognizesReportedEncoding() {
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "UTF8"))
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "UNICODE"))
        #expect(LibPQConnectionString.isClientEncoding(reportedByServer: "utf8"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: "EUC_JP"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: "SQL_ASCII"))
        #expect(!LibPQConnectionString.isClientEncoding(reportedByServer: nil))
    }
}
