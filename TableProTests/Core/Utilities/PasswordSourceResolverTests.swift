//
//  PasswordSourceResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("PasswordSourceResolver", .serialized)
struct PasswordSourceResolverTests {
    @Test("Reads a password from a file")
    func fileHappyPath() async throws {
        let url = try makeTempFile(contents: "filesecret")
        defer { try? FileManager.default.removeItem(at: url) }
        let password = try await PasswordSourceResolver.resolve(.file(path: url.path))
        #expect(password == "filesecret")
    }

    @Test("Trims a trailing newline from file contents")
    func fileTrimsNewline() async throws {
        let url = try makeTempFile(contents: "filesecret\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let password = try await PasswordSourceResolver.resolve(.file(path: url.path))
        #expect(password == "filesecret")
    }

    @Test("Expands a tilde in the file path")
    func fileExpandsTilde() async throws {
        let name = "tablepro_pwtest_\(UUID().uuidString).pw"
        let homeURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(name)
        try "tildesecret".write(to: homeURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let password = try await PasswordSourceResolver.resolve(.file(path: "~/\(name)"))
        #expect(password == "tildesecret")
    }

    @Test("Throws when the file does not exist")
    func fileNotFound() async {
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.file(path: "/nonexistent/tablepro/\(UUID().uuidString)"))
        }
    }

    @Test("Throws when the file is empty")
    func fileEmpty() async throws {
        let url = try makeTempFile(contents: "")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.file(path: url.path))
        }
    }

    @Test("Throws when the file holds only whitespace")
    func fileWhitespaceOnly() async throws {
        let url = try makeTempFile(contents: "   \n\t ")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.file(path: url.path))
        }
    }

    @Test("Resolves a file with loose permissions instead of refusing")
    func fileLoosePermissions() async throws {
        let url = try makeTempFile(contents: "loosesecret")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let password = try await PasswordSourceResolver.resolve(.file(path: url.path))
        #expect(password == "loosesecret")
    }

    @Test("Reads a password from an environment variable")
    func envHappyPath() async throws {
        let name = uniqueEnvName()
        setenv(name, "envsecret", 1)
        defer { unsetenv(name) }
        let password = try await PasswordSourceResolver.resolve(.env(variable: name))
        #expect(password == "envsecret")
    }

    @Test("Trims whitespace from an environment variable value")
    func envTrimsWhitespace() async throws {
        let name = uniqueEnvName()
        setenv(name, "  envsecret  ", 1)
        defer { unsetenv(name) }
        let password = try await PasswordSourceResolver.resolve(.env(variable: name))
        #expect(password == "envsecret")
    }

    @Test("Throws when the environment variable is not set")
    func envNotSet() async {
        let name = uniqueEnvName()
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.env(variable: name))
        }
    }

    @Test("Throws when the environment variable is empty")
    func envEmpty() async {
        let name = uniqueEnvName()
        setenv(name, "", 1)
        defer { unsetenv(name) }
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.env(variable: name))
        }
    }

    @Test("Reads a password from command stdout")
    func commandHappyPath() async throws {
        let password = try await PasswordSourceResolver.resolve(.command(shell: "printf 'cmdsecret'"))
        #expect(password == "cmdsecret")
    }

    @Test("Trims a trailing newline from command stdout")
    func commandTrimsNewline() async throws {
        let password = try await PasswordSourceResolver.resolve(.command(shell: "echo cmdsecret"))
        #expect(password == "cmdsecret")
    }

    @Test("Preserves interior spaces in command stdout")
    func commandPreservesSpaces() async throws {
        let password = try await PasswordSourceResolver.resolve(.command(shell: "printf 'a b c'"))
        #expect(password == "a b c")
    }

    @Test("Throws with exit code and stderr on non-zero exit")
    func commandNonZeroExit() async {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(shell: "echo boom >&2; exit 7", timeoutSeconds: 30)
            Issue.record("Expected resolveCommand to throw")
        } catch let error as PasswordSourceResolver.ResolutionError {
            guard case let .commandFailed(exitCode, stderr) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(exitCode == 7)
            #expect(stderr.contains("boom"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Throws when command produces empty stdout")
    func commandEmptyOutput() async {
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.command(shell: "true"))
        }
    }

    @Test("Rejects command output containing a NUL byte")
    func commandRejectsNul() async {
        await #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            try await PasswordSourceResolver.resolve(.command(shell: "printf 'a\\000b'"))
        }
    }

    @Test("Throws when command output exceeds the size cap")
    func commandOutputTooLarge() async {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(
                shell: "head -c 2000000 /dev/zero | tr '\\0' 'a'",
                timeoutSeconds: 30
            )
            Issue.record("Expected resolveCommand to reject oversized output")
        } catch let error as PasswordSourceResolver.ResolutionError {
            guard case .outputTooLarge = error else {
                Issue.record("Expected outputTooLarge, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Times out a slow command")
    func commandTimesOut() async {
        do {
            _ = try await PasswordSourceResolver.resolveCommand(shell: "sleep 5", timeoutSeconds: 1)
            Issue.record("Expected resolveCommand to time out")
        } catch let error as PasswordSourceResolver.ResolutionError {
            guard case .commandTimedOut = error else {
                Issue.record("Expected commandTimedOut, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Large stdout drains in full while stderr is also draining")
    func drainsLargeStdoutWithoutTruncation() async throws {
        let shell = """
        head -c 300000 /dev/zero | tr '\\0' 'a'
        head -c 300000 /dev/zero | tr '\\0' 'b' >&2
        """
        let output = try await PasswordSourceResolver.resolveCommand(shell: shell, timeoutSeconds: 30)
        #expect(output.count == 300_000)
        #expect(output.allSatisfy { $0 == "a" })
    }

    // MARK: - Secret manager references

    @Test("Local sources have no external command")
    func localSourcesHaveNoCommand() {
        #expect(PasswordSourceResolver.externalCommand(for: .file(path: "~/x")) == nil)
        #expect(PasswordSourceResolver.externalCommand(for: .env(variable: "X")) == nil)
        #expect(PasswordSourceResolver.externalCommand(for: .command(shell: "echo hi")) == nil)
    }

    @Test("1Password reference builds an op read command")
    func onePasswordCommand() {
        let command = PasswordSourceResolver.externalCommand(for: .onePassword(reference: "op://vault/db/password"))
        #expect(command == "op read --no-newline 'op://vault/db/password'")
    }

    @Test("Vault reference builds a vault kv get command")
    func vaultCommand() {
        let command = PasswordSourceResolver.externalCommand(for: .vault(path: "secret/data/db", field: "password"))
        #expect(command == "vault kv get -field='password' 'secret/data/db'")
    }

    @Test("AWS Secrets Manager reference builds an aws command")
    func awsCommand() {
        let command = PasswordSourceResolver.externalCommand(
            for: .awsSecretsManager(secretId: "prod/db", jsonKey: "password")
        )
        #expect(command == "aws secretsmanager get-secret-value --secret-id 'prod/db' --query SecretString --output text")
    }

    @Test("Shell quoting neutralizes injection attempts")
    func shellQuotingIsInjectionSafe() {
        let malicious = "x'; rm -rf ~ #"
        #expect(PasswordSourceResolver.shellQuote(malicious) == "'x'\\''; rm -rf ~ #'")

        let command = PasswordSourceResolver.externalCommand(for: .onePassword(reference: malicious))
        #expect(command == "op read --no-newline 'x'\\''; rm -rf ~ #'")
    }

    @Test("Extracts a JSON field from a secret string")
    func extractsJsonField() throws {
        let value = try PasswordSourceResolver.extractJsonField(
            "password", from: #"{"username":"admin","password":"s3cret"}"#
        )
        #expect(value == "s3cret")
    }

    @Test("Throws when the JSON key is missing")
    func throwsWhenJsonKeyMissing() {
        #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            _ = try PasswordSourceResolver.extractJsonField("password", from: #"{"username":"admin"}"#)
        }
    }

    @Test("Throws when the secret is not valid JSON")
    func throwsOnInvalidJson() {
        #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            _ = try PasswordSourceResolver.extractJsonField("password", from: "not json")
        }
    }

    @Test("Throws when the JSON value is null or a container, not a usable secret")
    func throwsOnNonStringJsonValue() {
        #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            _ = try PasswordSourceResolver.extractJsonField("password", from: #"{"password":null}"#)
        }
        #expect(throws: PasswordSourceResolver.ResolutionError.self) {
            _ = try PasswordSourceResolver.extractJsonField("password", from: #"{"password":{"nested":1}}"#)
        }
    }

    @Test("Extracts a numeric JSON value as its string form")
    func extractsNumericJsonValue() throws {
        let value = try PasswordSourceResolver.extractJsonField("secret", from: #"{"secret":5432}"#)
        #expect(value == "5432")
    }

    private func makeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro_pwtest_\(UUID().uuidString).pw")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func uniqueEnvName() -> String {
        "TABLEPRO_PWTEST_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}
