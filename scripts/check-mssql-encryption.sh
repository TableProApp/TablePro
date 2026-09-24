#!/usr/bin/env bash
#
# Check that every SQL Server SSL mode gets the encryption it names, against a real server, through the driver's own
# sources.
#
# db-lib has no per-connection encryption setting. dbsetlname refuses DBSETENCRYPT with error 20043, and the driver
# threw that answer away, so Disabled, Preferred and Required (skip verify) all ran at FreeTDS's default, which encrypts
# the login and nothing after it: sys.dm_exec_connections read encrypt_option FALSE for a Required connection. libtds
# reads the level, the CA file and the hostname check from freetds.conf alone, so the driver now writes each
# connection's server there, and this checks what the server says it got:
#
#   - Disabled and Preferred encrypt the login only, so encrypt_option reads FALSE, unless the server forces encryption.
#   - Required reads TRUE.
#   - Verify CA and Verify Identity read TRUE with the authority that signed the server's certificate, and are refused
#     without it. Verify Identity is refused for a host name the certificate does not carry, and Verify CA is not.
#   - Connections to one host with different modes, opened at the same time, each get their own mode.
#   - A connect to a server that never answers does not hold up a connect to another host, nor one to another port on
#     the same address, which is what every SSH tunnel on 127.0.0.1 is.
#   - A connect that waits for another connect to the same host name logs in once that one ends, and one that waits
#     longer than its login timeout gives up saying another connection holds the name, not that the server timed out.
#   - A password longer than db-lib takes fails the connect instead of logging in without one.
#   - A Windows Authentication connect deletes the Kerberos ticket cache it was handed however it fails, and a service
#     principal longer than the 128 bytes a login field takes reaches Kerberos.
#   - Against a server that cannot encrypt, which the check plays itself, Disabled and Preferred connect and Required is
#     refused, and only Required asks for encryption in the prelogin.
#
# Usage:
#   scripts/check-mssql-encryption.sh [host] [port] [user]
#
# The password comes from MSSQL_SA_PASSWORD, and the login needs VIEW SERVER STATE to read sys.dm_exec_connections.
# MSSQL_CA_FILE names the PEM the server's certificate chains to, MSSQL_CERT_HOST a host name the certificate carries
# (the host by default) and MSSQL_MISMATCH_HOST a name that reaches the server but is not in the certificate. Without
# MSSQL_CA_FILE the server is taken to present SQL Server's own self-signed certificate, which both verifying modes
# must refuse. Set MSSQL_FORCES_ENCRYPTION=1 for a server with forced encryption on.
#
# With no server listening on host:port, the script starts mcr.microsoft.com/azure-sql-edge in Docker as
# tablepro-mssql-encryption-check (or TP_MSSQL_CONTAINER), with a certificate for localhost from a CA it generates and
# keeps inside the container, and leaves it running for the next run. Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-14338}"
USER_NAME="${3:-sa}"
PASSWORD="${MSSQL_SA_PASSWORD:-}"
CA_FILE="${MSSQL_CA_FILE:-}"
CERT_HOST="${MSSQL_CERT_HOST:-$HOST}"
MISMATCH_HOST="${MSSQL_MISMATCH_HOST:-}"
FORCES_ENCRYPTION="${MSSQL_FORCES_ENCRYPTION:-0}"
DATABASE="${MSSQL_DATABASE:-master}"
CONTAINER="${TP_MSSQL_CONTAINER:-tablepro-mssql-encryption-check}"
IMAGE="mcr.microsoft.com/azure-sql-edge:latest"
CONTAINER_CA="/var/opt/mssql/tablepro-check-ca.pem"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

listening() {
    nc -z "$HOST" "$PORT" > /dev/null 2>&1
}

owns_container() {
    command -v docker > /dev/null 2>&1 && docker ps -a --format '{{.Names}}' | grep -x "$CONTAINER" > /dev/null
}

serves_address() {
    docker port "$CONTAINER" 1433/tcp 2> /dev/null | grep -x "$HOST:$PORT" > /dev/null
}

create_container() {
    local certs="$WORK/certs"
    mkdir -p "$certs"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=TablePro check CA" \
        -keyout "$certs/ca.key" -out "$certs/ca.pem" > /dev/null 2>&1 || return 1
    openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
        -keyout "$certs/server.key" -out "$certs/server.csr" > /dev/null 2>&1 || return 1
    printf 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$certs/server.ext"
    openssl x509 -req -days 3650 -in "$certs/server.csr" -CA "$certs/ca.pem" -CAkey "$certs/ca.key" \
        -CAcreateserial -extfile "$certs/server.ext" -out "$certs/server.pem" > /dev/null 2>&1 || return 1
    chmod 644 "$certs/server.key"
    printf '[network]\ntlscert = /var/opt/mssql/server.pem\ntlskey = /var/opt/mssql/server.key\ntlsprotocols = 1.2\n' \
        > "$certs/mssql.conf"

    docker create --name "$CONTAINER" -e ACCEPT_EULA=1 -e "MSSQL_SA_PASSWORD=$PASSWORD" \
        -p "$HOST:$PORT:1433" "$IMAGE" > /dev/null || return 1
    docker cp "$certs/mssql.conf" "$CONTAINER:/var/opt/mssql/mssql.conf" &&
        docker cp "$certs/server.pem" "$CONTAINER:/var/opt/mssql/server.pem" &&
        docker cp "$certs/server.key" "$CONTAINER:/var/opt/mssql/server.key" &&
        docker cp "$certs/ca.pem" "$CONTAINER:$CONTAINER_CA"
}

if ! listening; then
    command -v docker > /dev/null 2>&1 || {
        echo "no SQL Server at $HOST:$PORT and no docker to start one" >&2
        exit 3
    }
    if owns_container; then
        echo "starting container $CONTAINER"
    else
        if [ -z "$PASSWORD" ]; then
            PASSWORD="TpCheck#$(openssl rand -hex 8)"
            echo "generated a password for $CONTAINER; export MSSQL_SA_PASSWORD='$PASSWORD' to reuse it"
        fi
        echo "creating $CONTAINER from $IMAGE on $HOST:$PORT with a certificate for localhost"
        create_container || {
            echo "could not create $CONTAINER" >&2
            exit 3
        }
    fi
    docker start "$CONTAINER" > /dev/null || exit 3
    for _ in $(seq 1 60); do
        listening && break
        sleep 2
    done
fi

if [ -z "$CA_FILE" ] && owns_container && serves_address; then
    CA_FILE="$WORK/ca.pem"
    docker cp "$CONTAINER:$CONTAINER_CA" "$CA_FILE" > /dev/null || exit 3
    CERT_HOST="${MSSQL_CERT_HOST:-localhost}"
    MISMATCH_HOST="${MSSQL_MISMATCH_HOST:-127.0.0.1}"
fi

[ -n "$PASSWORD" ] || {
    echo "no password: set MSSQL_SA_PASSWORD for the server at $HOST:$PORT" >&2
    exit 3
}

mkdir -p "$WORK/Sources/Check"
ln -s "$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS" "$WORK/CFreeTDS"
for source in "$ROOT"/Plugins/MSSQLDriverPlugin/*.swift; do
    ln -s "$source" "$WORK/Sources/Check/$(basename "$source")"
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSSQLEncryptionCheck",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        .systemLibrary(name: "CFreeTDS", path: "CFreeTDS"),
        .executableTarget(
            name: "Check",
            dependencies: [
                "CFreeTDS",
                .product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProCoreTypes", package: "TableProCore"),
                .product(name: "TableProMSSQLCore", package: "TableProCore"),
                .product(name: "TableProLogRedaction", package: "TableProCore"),
            ],
            path: "Sources/Check",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags([
                "-L$ROOT/Libs", "-L$ROOT/Libs/dylibs", "-lsybdb", "-lssl.3", "-lcrypto.3", "-liconv",
                "-framework", "GSS", "-lcom_err", "-Xlinker", "-rpath", "-Xlinker", "$ROOT/Libs/dylibs",
            ])]
        ),
    ]
)
MANIFEST

cat > "$WORK/Sources/Check/Check.swift" << 'SWIFT'
import Darwin
import Foundation
import TableProMSSQLCore
import TableProPluginKit

@main
enum Check {
    nonisolated(unsafe) static var failures = 0

    static let environment = ProcessInfo.processInfo.environment
    static let host = environment["TP_CHECK_HOST"] ?? "127.0.0.1"
    static let port = Int(environment["TP_CHECK_PORT"] ?? "") ?? 1433
    static let caFile = environment["TP_CHECK_CA_FILE"].flatMap { $0.isEmpty ? nil : $0 }
    static let certHost = environment["TP_CHECK_CERT_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? host
    static let mismatchHost = environment["TP_CHECK_MISMATCH_HOST"].flatMap { $0.isEmpty ? nil : $0 }
    static let forcesEncryption = environment["TP_CHECK_FORCES_ENCRYPTION"] == "1"
    static let database = environment["TP_CHECK_DATABASE"] ?? "master"

    static func expect(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if condition {
            print("PASS: \(label)")
        } else {
            failures += 1
            print("FAIL: \(label) \(detail())")
        }
    }

    static func config(
        _ mode: SSLMode,
        host: String = Check.host,
        port: Int = Check.port,
        password: String? = nil,
        authority: String? = nil
    ) -> DriverConnectionConfig {
        DriverConnectionConfig(
            host: host,
            port: port,
            username: environment["TP_CHECK_USER"] ?? "sa",
            password: password ?? environment["TP_CHECK_PASSWORD"] ?? "",
            database: database,
            ssl: SSLConfiguration(mode: mode, caCertificatePath: authority ?? "")
        )
    }

    static func encryption(_ config: DriverConnectionConfig) async throws -> String {
        let driver = MSSQLPluginDriver(config: config)
        try await driver.connect()
        defer { driver.disconnect() }
        let result = try await driver.execute(
            query: "SELECT encrypt_option FROM sys.dm_exec_connections WHERE session_id = @@SPID"
        )
        return result.rows.first?.first?.asText ?? "no row"
    }

    static func outcome(_ config: DriverConnectionConfig) async -> String {
        do {
            return try await encryption(config)
        } catch {
            return "refused: \(error.localizedDescription)"
        }
    }

    static func waitForServer() async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                _ = try await encryption(config(.required))
                return
            } catch where Date() < deadline {
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            try await waitForServer()
            try await run()
        } catch {
            failures += 1
            print("FAIL: unexpected error \(error)")
        }
        print(failures == 0 ? "OK: every check passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func run() async throws {
        await eachModeGetsItsEncryption()
        await verifyingModesCheckTheCertificate()
        await concurrentModesOnOneHost()
        try await unansweredConnectHoldsUpNoOtherHost()
        try await unansweredConnectHoldsUpNoOtherPortOnTheAddress()
        try await waitForAHostNameIsBoundedAndSaysWhy()
        await overlongPasswordFailsTheConnect()
        await kerberosCacheIsDeletedWhateverEndsTheConnect()
        await longServicePrincipalReachesKerberos()
        await serverThatCannotEncrypt()
    }

    static func eachModeGetsItsEncryption() async {
        let unforced = forcesEncryption ? "TRUE" : "FALSE"
        for (mode, expected) in [(SSLMode.disabled, unforced), (.preferred, unforced), (.required, "TRUE")] {
            let seen = await outcome(config(mode))
            expect(seen == expected, "\(mode.rawValue) reads encrypt_option \(expected)", "got \(seen)")
        }
    }

    static func verifyingModesCheckTheCertificate() async {
        guard let caFile else {
            for mode in [SSLMode.verifyCa, .verifyIdentity] {
                let seen = await outcome(config(mode))
                expect(seen.hasPrefix("refused"), "\(mode.rawValue) refuses a certificate the system roots do not vouch for",
                       "got \(seen)")
            }
            return
        }
        let chained = await outcome(config(.verifyCa, authority: caFile))
        expect(chained == "TRUE", "Verify CA with the signing authority reads encrypt_option TRUE", "got \(chained)")
        let untrusted = await outcome(config(.verifyCa))
        expect(untrusted.hasPrefix("refused"), "Verify CA refuses the certificate against the system roots alone",
               "got \(untrusted)")
        let named = await outcome(config(.verifyIdentity, host: certHost, authority: caFile))
        expect(named == "TRUE", "Verify Identity through \(certHost), a name the certificate carries, reads TRUE",
               "got \(named)")
        if let mismatchHost {
            let unnamed = await outcome(config(.verifyIdentity, host: mismatchHost, authority: caFile))
            expect(unnamed.hasPrefix("refused"),
                   "Verify Identity through \(mismatchHost), a name the certificate does not carry, is refused",
                   "got \(unnamed)")
            let chainOnly = await outcome(config(.verifyCa, host: mismatchHost, authority: caFile))
            expect(chainOnly == "TRUE", "Verify CA through \(mismatchHost) does not check the name", "got \(chainOnly)")
        }
    }

    static func concurrentModesOnOneHost() async {
        let unforced = forcesEncryption ? "TRUE" : "FALSE"
        let modes = (0..<8).map { $0.isMultiple(of: 2) ? SSLMode.disabled : .required }
        let seen = await withTaskGroup(of: (Int, String).self) { group in
            for (index, mode) in modes.enumerated() {
                group.addTask { (index, await outcome(config(mode))) }
            }
            var answers = [String](repeating: "", count: modes.count)
            for await (index, answer) in group {
                answers[index] = answer
            }
            return answers
        }
        let expected = modes.map { $0 == .required ? "TRUE" : unforced }
        expect(seen == expected, "8 connections to one host opened together, alternating Disabled and Required, each get their own",
               "got \(seen)")
    }

    static func unansweredConnectHoldsUpNoOtherHost() async throws {
        guard let listener = SilentListener() else {
            expect(false, "a listener that never answers could be opened")
            return
        }
        let silentHost = host == "127.0.0.1" ? "localhost" : "127.0.0.1"

        let silentFinished = Flag()
        let silent = Task {
            let answer = await outcome(config(.required, host: silentHost, port: listener.port))
            silentFinished.set()
            return answer
        }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let started = Date()
        let live = await outcome(config(.required))
        let elapsed = Date().timeIntervalSince(started)
        let silentStillWaiting = !silentFinished.isSet
        listener.close()
        let silentOutcome = await silent.value

        expect(live == "TRUE" && elapsed < 10 && silentStillWaiting,
               "a connect to \(host) finishes while one to \(silentHost), which never answers, is still waiting",
               String(format: "live=%@ in %.1fs", live, elapsed))
        expect(silentOutcome.hasPrefix("refused"), "the connect that never got an answer fails once its server goes",
               "got \(silentOutcome)")
    }

    static func unansweredConnectHoldsUpNoOtherPortOnTheAddress() async throws {
        guard host == "127.0.0.1" else {
            print("SKIP: connects to other ports on one address need the server on 127.0.0.1")
            return
        }
        guard let first = SilentListener(), let second = SilentListener() else {
            expect(false, "two listeners that never answer could be opened")
            return
        }
        let silentFinished = Flag()
        let silent = Task {
            async let one = outcome(config(.preferred, host: "127.0.0.1", port: first.port))
            async let two = outcome(config(.required, host: "127.0.0.1", port: second.port))
            let answers = await [one, two]
            silentFinished.set()
            return answers
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let started = Date()
        let live = await outcome(config(.required))
        let elapsed = Date().timeIntervalSince(started)
        let silentStillWaiting = !silentFinished.isSet
        first.close()
        second.close()
        let silentOutcomes = await silent.value

        expect(live == "TRUE" && elapsed < 10 && silentStillWaiting,
               "a connect to 127.0.0.1:\(port) finishes while two to other ports on 127.0.0.1, which never answer, wait",
               String(format: "live=%@ in %.1fs", live, elapsed))
        expect(silentOutcomes.allSatisfy { $0.hasPrefix("refused") },
               "the connects that never got an answer fail once their servers go", "got \(silentOutcomes)")
    }

    static func waitForAHostNameIsBoundedAndSaysWhy() async throws {
        guard host == "127.0.0.1" else {
            print("SKIP: a wait for localhost needs the server on 127.0.0.1")
            return
        }
        guard let first = SilentListener(), let second = SilentListener() else {
            expect(false, "two listeners that never answer could be opened")
            return
        }

        let holder = Task { await outcome(config(.required, host: "localhost", port: first.port)) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        var started = Date()
        let waiter = Task { await outcome(config(.required, host: "localhost")) }
        try await Task.sleep(nanoseconds: 10_000_000_000)
        first.close()
        let waited = await waiter.value
        var elapsed = Date().timeIntervalSince(started)
        _ = await holder.value
        expect(waited == "TRUE" && elapsed > 9,
               "a connect to localhost that waits for another to localhost logs in once that one ends",
               String(format: "live=%@ after %.1fs", waited, elapsed))

        guard let third = SilentListener() else {
            expect(false, "a third listener that never answers could be opened")
            return
        }
        let holders = Task {
            async let one = outcome(config(.required, host: "localhost", port: second.port))
            try? await Task.sleep(nanoseconds: 500_000_000)
            async let two = outcome(config(.required, host: "localhost", port: third.port))
            return await [one, two]
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        started = Date()
        let starved = await outcome(config(.required, host: "localhost"))
        elapsed = Date().timeIntervalSince(started)
        second.close()
        third.close()
        let holderOutcomes = await holders.value

        let limit = Double(MSSQLConnectionOptions.defaultLoginTimeoutSeconds + 5)
        expect(starved.contains("Another connection to localhost") && elapsed >= limit - 1 && elapsed < limit + 5,
               "a connect to localhost behind two others that never answer gives up at its limit and says why",
               String(format: "got %@ after %.1fs", starved, elapsed))
        expect(holderOutcomes.allSatisfy { $0.hasPrefix("refused") },
               "the connects that held localhost fail once their servers go", "got \(holderOutcomes)")
    }

    static func overlongPasswordFailsTheConnect() async {
        let seen = await outcome(config(.required, password: String(repeating: "p", count: 200)))
        expect(seen.hasPrefix("refused") && seen.contains("128 bytes"),
               "a password db-lib refuses fails the connect and says why", "got \(seen)")
    }

    static func windowsOptions(
        host: String = Check.host,
        database: String = Check.database,
        servicePrincipal: String? = nil,
        cachePath: String? = nil
    ) -> MSSQLConnectionOptions {
        MSSQLConnectionOptions(
            host: host,
            port: port,
            user: "",
            password: "",
            database: database,
            encryptionLevel: .require,
            authMethod: .windows,
            kerberosCachePath: cachePath,
            kerberosServicePrincipal: servicePrincipal
        )
    }

    static func windowsConnectFailure(_ options: MSSQLConnectionOptions) async -> String? {
        let connection = FreeTDSConnection(options: options)
        do {
            try await connection.connect()
            connection.disconnect()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func kerberosCacheIsDeletedWhateverEndsTheConnect() async {
        let tooLongPrincipal = "MSSQLSvc/" + String(repeating: "h", count: 240) + ":\(port)@EXAMPLE.COM"
        let cases: [(label: String, options: (String) -> MSSQLConnectionOptions)] = [
            ("a database name db-lib refuses", { windowsOptions(database: String(repeating: "d", count: 129), cachePath: $0) }),
            ("a host FreeTDS cannot be given", { windowsOptions(host: "[\(host)", cachePath: $0) }),
            ("a service principal FreeTDS cannot be given",
             { windowsOptions(servicePrincipal: tooLongPrincipal, cachePath: $0) }),
            ("a login Kerberos refuses", { windowsOptions(cachePath: $0) })
        ]
        for (label, options) in cases {
            let cachePath = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("tablepro-krb5-check-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: cachePath, contents: Data("ticket".utf8)) else {
                expect(false, "a stand-in ticket cache could be written")
                return
            }
            let failure = await windowsConnectFailure(options(cachePath))
            let survived = FileManager.default.fileExists(atPath: cachePath)
            try? FileManager.default.removeItem(atPath: cachePath)
            expect(failure != nil && !survived, "the ticket cache is gone after \(label) fails the connect",
                   "failure=\(failure ?? "none") cache survived=\(survived)")
        }
    }

    static func longServicePrincipalReachesKerberos() async {
        let principal = "MSSQLSvc/sql-prod-availability-group-listener-001.finance.emea.corp.contoso-international.com"
            + ":\(port)@CORP.CONTOSO-INTERNATIONAL.COM"
        let failure = await windowsConnectFailure(windowsOptions(servicePrincipal: principal)) ?? "connected"
        let refusedBeforeKerberos = failure.contains("128 bytes") || failure.contains("cannot be passed to FreeTDS")
        expect(principal.utf8.count > 128 && failure != "connected" && !refusedBeforeKerberos,
               "a \(principal.utf8.count)-byte service principal is handed to Kerberos, which fails without a ticket",
               "got \(failure)")
    }

    static func connectFailure(_ config: DriverConnectionConfig) async -> String? {
        let driver = MSSQLPluginDriver(config: config)
        do {
            try await driver.connect()
            driver.disconnect()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func serverThatCannotEncrypt() async {
        guard let server = ServerWithoutEncryption() else {
            expect(false, "a server that cannot encrypt could be started")
            return
        }
        server.start()
        defer { server.stop() }
        for mode in [SSLMode.disabled, .preferred] {
            let failure = await connectFailure(config(mode, host: "127.0.0.1", port: server.port))
            expect(failure == nil, "\(mode.rawValue) connects to a server that cannot encrypt", "got \(failure ?? "")")
        }
        let required = await connectFailure(config(.required, host: "127.0.0.1", port: server.port))
        expect(required != nil, "Required refuses a server that cannot encrypt", "it connected")
        expect(server.encryptionOffers == [0, 0, 1],
               "the prelogin offers encryption off for Disabled and Preferred and on for Required",
               "got \(server.encryptionOffers)")
    }
}

/// Answers the TDS prelogin with ENCRYPT_NOT_SUP, the login with a LOGINACK and every other request with a DONE, which
/// is all the driver needs to connect. It records the encryption byte each prelogin offers.
final class ServerWithoutEncryption: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var offers: [UInt8] = []

    private static let preloginReply: [UInt8] = [
        0x00, 0x00, 0x0B, 0x00, 0x06, 0x01, 0x00, 0x11, 0x00, 0x01, 0xFF,
        15, 0, 0x07, 0xD0, 0, 0,
        0x02,
    ]
    private static let loginAck: [UInt8] = [
        0xAD, 18, 0, 1, 0x74, 0, 0, 4, 4, 0x66, 0, 0x61, 0, 0x6B, 0, 0x65, 0, 15, 0, 0, 0,
    ]
    private static let packetSizeChange: [UInt8] = [
        0xE3, 19, 0, 4, 4, 0x34, 0, 0x30, 0, 0x39, 0, 0x36, 0, 4, 0x34, 0, 0x30, 0, 0x39, 0, 0x36, 0,
    ]
    private static let done: [UInt8] = [0xFD, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard bound else {
            close(fd)
            return nil
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    var encryptionOffers: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return offers
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        while let (type, body) = readMessage(client) {
            switch type {
            case 0x12:
                if let offer = Self.encryptionOffer(in: body) {
                    lock.lock()
                    offers.append(offer)
                    lock.unlock()
                }
                send(Self.preloginReply, to: client)
            case 0x10:
                send(Self.loginAck + Self.packetSizeChange + Self.done, to: client)
            default:
                send(Self.done, to: client)
            }
        }
    }

    private static func encryptionOffer(in body: [UInt8]) -> UInt8? {
        var index = 0
        while index + 4 < body.count, body[index] != 0xFF {
            let offset = Int(body[index + 1]) << 8 | Int(body[index + 2])
            if body[index] == 0x01, offset < body.count {
                return body[offset]
            }
            index += 5
        }
        return nil
    }

    private func readMessage(_ client: Int32) -> (UInt8, [UInt8])? {
        var body: [UInt8] = []
        while true {
            guard let header = read(8, from: client) else { return nil }
            let length = Int(header[2]) << 8 | Int(header[3])
            guard length >= 8, let payload = read(length - 8, from: client) else { return nil }
            body += payload
            if header[1] & 0x01 != 0 {
                return (header[0], body)
            }
        }
    }

    private func read(_ count: Int, from client: Int32) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let chunk = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return recv(client, base + received, count - received, 0)
            }
            guard chunk > 0 else { return nil }
            received += chunk
        }
        return bytes
    }

    private func send(_ payload: [UInt8], to client: Int32) {
        let length = payload.count + 8
        let packet: [UInt8] = [0x04, 0x01, UInt8(length >> 8), UInt8(length & 0xFF), 0, 0, 1, 0] + payload
        _ = packet.withUnsafeBytes { Darwin.send(client, $0.baseAddress, packet.count, 0) }
    }
}

/// Takes connections on 127.0.0.1 and never answers, which is what a tunnel to a server that has gone quiet does.
/// Closing it resets every connection still waiting on it.
final class SilentListener: @unchecked Sendable {
    let port: Int
    private let descriptor: Int32

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(fd, generic, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, generic, &length) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            return nil
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func close() {
        Darwin.close(descriptor)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func set() {
        lock.lock()
        raised = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
SWIFT

export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
swift build --package-path "$WORK" --scratch-path "$WORK/.build" > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    grep -E "error:" "$WORK/build.log" >&2
    exit 3
}

TP_CHECK_HOST="$HOST" TP_CHECK_PORT="$PORT" TP_CHECK_USER="$USER_NAME" TP_CHECK_PASSWORD="$PASSWORD" \
    TP_CHECK_CA_FILE="$CA_FILE" TP_CHECK_CERT_HOST="$CERT_HOST" TP_CHECK_MISMATCH_HOST="$MISMATCH_HOST" \
    TP_CHECK_FORCES_ENCRYPTION="$FORCES_ENCRYPTION" TP_CHECK_DATABASE="$DATABASE" \
    "$WORK/.build/debug/Check"
