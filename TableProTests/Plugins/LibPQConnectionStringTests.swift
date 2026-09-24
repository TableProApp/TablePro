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
        options: String? = nil,
        applicationName: String? = nil
    ) -> String {
        LibPQConnectionString.build(
            host: "db.example.com",
            port: 5_432,
            user: user,
            password: password,
            database: "app",
            sslConfig: sslConfig,
            options: options,
            applicationName: applicationName
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

    @Test("The application name reaches libpq as a fallback, ahead of the connection options")
    func sendsFallbackApplicationName() {
        let conninfo = build(options: "-c search_path=app", applicationName: "TablePro Metadata")

        #expect(conninfo.hasSuffix(
            "client_encoding='UTF8' fallback_application_name='TablePro Metadata' options='-c search_path=app'"
        ))
        #expect(!conninfo.contains(" application_name="))
    }

    @Test("No application name, or an empty one, sends no application name keyword")
    func omitsMissingApplicationName() {
        #expect(!build().contains("application_name"))
        #expect(!build(applicationName: "").contains("application_name"))
    }

    /// Measured on libpq 17: a fallback name replaces an `application_name` set in `options`, so it
    /// has to stay out whenever the user named the session there, in any of the server's spellings.
    @Test(
        "A name the user gives the session in the connection options keeps the fallback out",
        arguments: [
            "-c application_name=reporting",
            "-capplication_name=reporting",
            "--application_name=reporting",
            "-c application-name=reporting",
            "--application-name=reporting",
            "-c Application_Name=reporting"
        ]
    )
    func userApplicationNameWins(options: String) {
        let conninfo = build(options: options, applicationName: "TablePro")

        #expect(!conninfo.contains("fallback_application_name"))
        #expect(conninfo.contains("options="))
    }

    @Test(
        "An option that only mentions application_name in its value still gets the fallback",
        arguments: ["-c search_path=application_name,public", "--search-path=application_name", "-c statement_timeout=0"]
    )
    func valuesDoNotNameTheApplication(options: String) {
        #expect(build(options: options, applicationName: "TablePro").contains("fallback_application_name='TablePro'"))
    }

    @Test("Each setting in the options is read by its name, in every spelling the server takes")
    func readsSettingNames() {
        #expect(
            LibPQConnectionString.settingNames(in: "-c Search_Path=x -cstatement_timeout=0 --work-mem=64MB -c")
                == ["search_path", "statement_timeout", "work_mem"]
        )
    }

    @Test("A quote or backslash in the application name is escaped")
    func escapesApplicationName() {
        #expect(build(applicationName: "o'brien\\x").contains("fallback_application_name='o\\'brien\\\\x'"))
    }

    @Test("A metadata connection is named apart from the session, and anything else is the session")
    func namesEachPurpose() {
        #expect(LibPQConnectionString.applicationName(forPurpose: "metadata") == "TablePro Metadata")
        #expect(LibPQConnectionString.applicationName(forPurpose: "session") == "TablePro")
        #expect(LibPQConnectionString.applicationName(forPurpose: nil) == "TablePro")
        #expect(LibPQConnectionString.applicationName(forPurpose: "other") == "TablePro")
    }

    @Test("Both names fit the server's 63-byte limit and are plain ASCII")
    func namesFitTheServerLimit() {
        for name in [LibPQConnectionString.sessionApplicationName, LibPQConnectionString.metadataApplicationName] {
            #expect(name.utf8.count <= 63)
            #expect(name.allSatisfy { $0.isASCII })
        }
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
