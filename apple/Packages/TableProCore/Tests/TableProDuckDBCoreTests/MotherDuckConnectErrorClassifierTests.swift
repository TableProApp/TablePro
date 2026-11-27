import Foundation
import TableProDuckDBCore
import Testing

private struct DuckDBText: Error, LocalizedError {
    let text: String
    var errorDescription: String? { text }
}

// Each text is what DuckDB returned on 2026-11-23, from the official CLIs or the C API.
private let initRefusedVersion = "Invalid Input Error: Initialization function \"motherduck_duckdb_cpp_init\" from file "
    + "\"/Users/me/.duckdb/extensions/v2.0.0/osx_arm64/motherduck.duckdb_extension\" threw an exception: \"\n"
    + "Your DuckDB version (v2.0.0) is not yet supported by MotherDuck. The latest supported version is v1.5.6. "
    + "Please downgrade to use MotherDuck.\""
private let serviceRefusedVersion = "Invalid Configuration Error: Your MotherDuck extension is running on DuckDB v2.0.1 "
    + "which is not yet supported. Please downgrade your DuckDB. We recommend DuckDB v1.5.6. "
    + "(you are using version v2.0.1-2026-11-867)"
private let badToken = "Invalid Error: Request failed: Your request is not authenticated. Please check your MotherDuck "
    + "token. (Jwt verification fails, request id: '81a20903')"
private let unreachable = "Invalid Error: Request failed: Could not connect to MotherDuck. Please try again later or "
    + "contact support@motherduck.com for help. (UNAVAILABLE, RPC 'CREATE_SLT', request id: '81a2090a')"
private let timedOut = "Connection Error: Timed out connecting to MotherDuck after 30000ms. Use "
    + "'motherduck_connection_timeout' to change the timeout."
private let noRouteInstall = "IO Error: Failed to download extension \"motherduck\" at URL "
    + "\"http://extensions.duckdb.org/v2.0.1/osx_arm64/motherduck.duckdb_extension.gz\" (ERROR Could not establish connection)"
private let noRouteLoad = "Invalid Input Error: Initialization function \"motherduck_duckdb_cpp_init\" from file \"x\" "
    + "threw an exception: \"Failed to download \"http://api.motherduck.com/extension_version\" (attempt 5): "
    + "Could not establish connection\""
private let otherBuild = "Invalid Input Error: Failed to load 'motherduck', The file was built specifically for DuckDB "
    + "version 'v2.0.0' and can only be loaded with that version of DuckDB. (this version of DuckDB is 'v2.0.1')"
private let missingDatabase = "Catalog Error: no database/share named \"nope\" found"

struct MotherDuckConnectErrorClassifierTests {
    @Test("A DuckDB the extension or the service does not support yet says so, whichever refused it")
    func versionNotSupported() {
        #expect(MotherDuckConnectErrorClassifier.classify(message: initRefusedVersion)
            == .versionNotSupported(detail: initRefusedVersion))
        #expect(MotherDuckConnectErrorClassifier.classify(message: serviceRefusedVersion)
            == .versionNotSupported(detail: serviceRefusedVersion))
    }

    @Test("The loader's report of the init refusal is still a version refusal")
    func versionThroughTheLoader() {
        let error = QuackConnectError.extensionNotLoaded(name: "motherduck", detail: initRefusedVersion)
        #expect(MotherDuckConnectErrorClassifier.classify(error) == .versionNotSupported(detail: initRefusedVersion))
    }

    @Test("A token the service rejects names the token")
    func tokenRejected() {
        #expect(MotherDuckConnectErrorClassifier.classify(DuckDBText(text: badToken)) == .tokenRejected(detail: badToken))
    }

    @Test("No route to the service reads as unreachable")
    func unreachableService() {
        #expect(MotherDuckConnectErrorClassifier.classify(message: unreachable) == .unreachable(detail: unreachable))
    }

    @Test("MotherDuck's own timeout is the attempt's deadline, so it reads as the connect timing out")
    func serviceTimeout() {
        #expect(MotherDuckConnectErrorClassifier.classify(message: timedOut) == .timedOut)
    }

    @Test("A download or init that needs a host it cannot reach, or a file for another DuckDB, is the extension", arguments: [
        noRouteInstall, noRouteLoad, otherBuild,
    ])
    func extensionUnavailable(text: String) {
        #expect(MotherDuckConnectErrorClassifier.classify(message: text) == .extensionUnavailable(detail: text))
    }

    @Test("Any loader failure is about the extension, even with a text this does not know")
    func loaderFailure() {
        let error = QuackConnectError.extensionNotInstalled(name: "motherduck", detail: "IO Error: something new")
        #expect(MotherDuckConnectErrorClassifier.classify(error) == .extensionUnavailable(detail: "IO Error: something new"))
    }

    @Test("Anything else keeps DuckDB's own text")
    func unknownKeepsItsText() {
        #expect(MotherDuckConnectErrorClassifier.classify(message: missingDatabase) == nil)
    }

    @Test("Each message keeps DuckDB's text at the end")
    func messagesKeepTheDetail() throws {
        let message = try #require(MotherDuckConnectError.tokenRejected(detail: badToken).errorDescription)
        #expect(message.hasSuffix(badToken))
        #expect(message.contains("Access Token"))
    }
}
