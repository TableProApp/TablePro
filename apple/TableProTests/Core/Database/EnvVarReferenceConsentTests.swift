//
//  EnvVarReferenceConsentTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSSHConfig
import Testing

@MainActor
private final class EnvVarQuestionSpy {
    var answer: ConsentAnswer
    private(set) var questions: [EnvVarReferenceQuestion] = []

    init(answer: ConsentAnswer) {
        self.answer = answer
    }

    func ask(_ question: EnvVarReferenceQuestion) async -> ConsentAnswer {
        questions.append(question)
        return answer
    }
}

extension GlobalStateSuites {
    // Sets the report's two variables in the test host's own environment, which every suite shares.
    @MainActor
    struct EnvVarReferenceConsentTests {
        private static let passwordName = "PROD_DB_PASSWORD"
        private static let secretKeyName = "AWS_SECRET_ACCESS_KEY"

        private let suite: EphemeralDefaults
        private let store: EnvVarReferenceApprovalStore
        private let spy: EnvVarQuestionSpy
        private let password = "pw-" + UUID().uuidString
        private let secretKey = "sk-" + UUID().uuidString

        init() throws {
            suite = try EphemeralDefaults()
            store = EnvVarReferenceApprovalStore(defaults: suite.defaults, savedConnections: { [] })
            spy = EnvVarQuestionSpy(answer: .declined)
        }

        private func makeConsent(licensed: Bool = true) -> EnvVarReferenceConsent {
            EnvVarReferenceConsent(
                approvals: store,
                isFeatureAvailable: { licensed },
                ask: { [spy] question in await spy.ask(question) }
            )
        }

        // The file in the report, after import: its author picked both the variables and the server.
        private func importedFromAttacker() -> DatabaseConnection {
            var connection = DatabaseConnection(
                name: "Staging",
                host: "pg.attacker.example",
                port: 5_432,
                database: "${AWS_SECRET_ACCESS_KEY}",
                username: "$PROD_DB_PASSWORD",
                type: .postgresql
            )
            connection.origin = .imported
            return connection
        }

        @discardableResult
        private func withReportVariables<T>(_ body: () async throws -> T) async rethrows -> T {
            let previous = [Self.passwordName, Self.secretKeyName].map { name in
                (name, ProcessInfo.processInfo.environment[name])
            }
            setenv(Self.passwordName, password, 1)
            setenv(Self.secretKeyName, secretKey, 1)
            defer {
                for (name, value) in previous {
                    if let value {
                        setenv(name, value, 1)
                    } else {
                        unsetenv(name)
                    }
                }
            }
            return try await body()
        }

        @Test("A connect TablePro starts on its own is refused before anything is read")
        func backgroundIsRefused() async {
            let consent = makeConsent()
            let connection = importedFromAttacker()
            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.needsPerson) {
                    _ = try await consent.resolve(connection, trigger: .background)
                }
            }
            #expect(spy.questions.isEmpty)
            #expect(!store.isApproved(connection))
        }

        @Test("A declined prompt sends nothing and approves nothing")
        func declinedSendsNothing() async {
            let consent = makeConsent()
            let connection = importedFromAttacker()
            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.declined) {
                    _ = try await consent.resolve(connection, trigger: .request)
                }
            }
            #expect(spy.questions.count == 1)
            #expect(!store.isApproved(connection))
        }

        @Test("An unanswered prompt is a refusal of its own")
        func unansweredIsRefused() async {
            spy.answer = .unanswered
            let consent = makeConsent()
            let connection = importedFromAttacker()
            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.unanswered) {
                    _ = try await consent.resolve(connection, trigger: .request)
                }
            }
            #expect(!store.isApproved(connection))
        }

        private func bridgeAsking(about connection: DatabaseConnection) throws -> (DatabaseAccessBridge, () -> Void) {
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-envvar-bridge-\(UUID().uuidString).json")
            let storageSuite = try EphemeralDefaults()
            let storage = ConnectionStorage(
                fileURL: fileURL,
                userDefaults: storageSuite.defaults,
                keychain: InMemoryKeychain()
            )
            storage.addConnection(connection)
            let manager = DatabaseManager(connectionStorage: storage, envVarReferenceConsent: makeConsent())
            return (DatabaseAccessBridge(manager: manager), {
                manager.removeSession(for: connection.id)
                storageSuite.defaults.removePersistentDomain(forName: storageSuite.suiteName)
                try? FileManager.default.removeItem(at: fileURL)
            })
        }

        @Test("MCP, the assistant and AppleScript get a declined prompt as a refusal")
        func bridgeReportsDeclinedAsForbidden() async throws {
            let connection = importedFromAttacker()
            let (bridge, cleanUp) = try bridgeAsking(about: connection)
            defer { cleanUp() }

            do {
                _ = try await bridge.connect(connectionId: connection.id)
                Issue.record("The connect went ahead without consent")
            } catch DatabaseAccessError.forbidden {
            } catch {
                Issue.record("Unexpected error \(error)")
            }
            #expect(spy.questions.count == 1)
            #expect(!store.isApproved(connection))
        }

        @Test("A bridge tool call that needs a session reports an unanswered prompt as a timeout")
        func bridgeReportsUnansweredAsTimeout() async throws {
            spy.answer = .unanswered
            let connection = importedFromAttacker()
            let (bridge, cleanUp) = try bridgeAsking(about: connection)
            defer { cleanUp() }

            do {
                try await bridge.ensureConnected(connection.id)
                Issue.record("The connect went ahead without consent")
            } catch DatabaseAccessError.timeout {
            } catch {
                Issue.record("Unexpected error \(error)")
            }
            #expect(spy.questions.count == 1)
        }

        @Test("An approved connection resolves without asking, in the background too")
        func approvedResolves() async throws {
            let connection = importedFromAttacker()
            store.approveReferences(of: connection)

            let resolved = try await withReportVariables {
                try await makeConsent().resolve(connection, trigger: .background)
            }

            #expect(resolved.username == password)
            #expect(resolved.database == secretKey)
            #expect(resolved.host == "pg.attacker.example")
            #expect(spy.questions.isEmpty)
        }

        @Test("A yes at the connect resolves it and the next one")
        func promptApprovalIsKept() async throws {
            spy.answer = .approved
            let connection = importedFromAttacker()

            let resolved = try await withReportVariables { () async throws -> [DatabaseConnection] in
                let first = try await makeConsent().resolve(connection, trigger: .request)
                let second = try await makeConsent().resolve(connection, trigger: .background)
                return [first, second]
            }

            #expect(resolved.map { $0.username } == [password, password])
            #expect(spy.questions.count == 1)
        }

        @Test("A gesture that asked first is not asked again at the connect")
        func gestureAsksOnce() async throws {
            spy.answer = .approved
            let consent = makeConsent()
            let connection = importedFromAttacker()
            #expect(consent.requiresApproval(connection))

            #expect(await consent.confirm(connection))
            let resolved = try await withReportVariables {
                try await consent.resolve(connection, trigger: .request)
            }

            #expect(!consent.requiresApproval(connection))
            #expect(resolved.username == password)
            #expect(spy.questions.count == 1)
        }

        @Test("A declined gesture leaves nothing approved")
        func declinedGestureApprovesNothing() async {
            let consent = makeConsent()
            let connection = importedFromAttacker()

            #expect(await consent.confirm(connection) == false)
            #expect(consent.requiresApproval(connection))
            await #expect(throws: EnvVarReferenceConsentError.needsPerson) {
                _ = try await consent.resolve(connection, trigger: .background)
            }
        }

        @Test("A changed host asks again")
        func hostChangeAsksAgain() async {
            let consent = makeConsent()
            var connection = importedFromAttacker()
            connection.host = "pg.internal.example"
            store.approveReferences(of: connection)
            connection.host = "pg.attacker.example"
            let moved = connection

            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.needsPerson) {
                    _ = try await consent.resolve(moved, trigger: .background)
                }
                _ = try? await consent.resolve(moved, trigger: .request)
            }

            #expect(spy.questions.map { $0.destination } == ["pg.attacker.example:5432"])
        }

        @Test("A new variable name asks again")
        func newNameAsksAgain() async {
            let consent = makeConsent()
            var connection = importedFromAttacker()
            connection.database = "app"
            store.approveReferences(of: connection)
            connection.database = "${AWS_SECRET_ACCESS_KEY}"
            let widened = connection

            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.needsPerson) {
                    _ = try await consent.resolve(widened, trigger: .background)
                }
            }
        }

        @Test("Saving the connection form approves what it saved")
        func formSaveApproves() async throws {
            var connection = importedFromAttacker()
            connection.origin = .thisMac
            store.approveReferences(of: connection)

            let resolved = try await withReportVariables {
                try await makeConsent().resolve(connection, trigger: .background)
            }

            #expect(resolved.username == password)
        }

        @Test("Deleting the connection revokes its approval")
        func revokeClears() async {
            let consent = makeConsent()
            let connection = importedFromAttacker()
            store.approveReferences(of: connection)

            store.revoke(for: connection.id)

            await withReportVariables {
                await #expect(throws: EnvVarReferenceConsentError.needsPerson) {
                    _ = try await consent.resolve(connection, trigger: .background)
                }
            }
        }

        @Test("A duplicate carries its source's approval")
        func copyCarries() async throws {
            let source = importedFromAttacker()
            store.approveReferences(of: source)
            var duplicate = importedFromAttacker()
            duplicate.name = "Staging (Copy)"

            store.copyApprovals(from: source.id, to: duplicate.id)
            let resolved = try await withReportVariables {
                try await makeConsent().resolve(duplicate, trigger: .background)
            }

            #expect(resolved.database == secretKey)
        }

        @Test("Without the license nothing is read and nothing is asked")
        func unlicensedLeavesReferencesAsWritten() async throws {
            let consent = makeConsent(licensed: false)
            let connection = importedFromAttacker()

            let resolved = try await withReportVariables {
                try await consent.resolve(connection, trigger: .background)
            }

            #expect(resolved == connection)
            #expect(!consent.requiresApproval(connection))
            #expect(spy.questions.isEmpty)
        }

        @Test("A connection with no references connects as it is, in the background too")
        func noReferencesIsUnchanged() async throws {
            let plain = DatabaseConnection(name: "Plain", host: "db.example.com", username: "app", type: .postgresql)

            let resolved = try await makeConsent().resolve(plain, trigger: .background)

            #expect(resolved == plain)
            #expect(spy.questions.isEmpty)
        }

        @Test("The prompt names the variables and the server, never a value")
        func promptShowsNamesNotValues() async throws {
            let consent = makeConsent()
            let connection = importedFromAttacker()
            await withReportVariables {
                _ = try? await consent.resolve(connection, trigger: .request)
            }
            let question = try #require(spy.questions.first)

            #expect(question.names == ["AWS_SECRET_ACCESS_KEY", "PROD_DB_PASSWORD"])
            #expect(question.destination == "pg.attacker.example:5432")
            #expect(question.origin == .imported)

            let message = EnvVarReferencePrompt.message(for: question)
            #expect(message.contains("$PROD_DB_PASSWORD"))
            #expect(message.contains("$AWS_SECRET_ACCESS_KEY"))
            #expect(message.contains("pg.attacker.example:5432"))
            #expect(!message.contains(password))
            #expect(!message.contains(secretKey))
        }

        @Test("The prompt names the SSH server a tunnelled connection goes through")
        func promptNamesTheSSHServer() {
            var connection = importedFromAttacker()
            var ssh = connection.sshConfig
            ssh.enabled = true
            ssh.host = "bastion.example.com"
            ssh.port = 2_222
            connection.sshConfig = ssh
            connection.sshTunnelMode = .inline(ssh)

            let destination = EnvVarReferenceConsent.question(for: connection).destination

            #expect(destination.contains("pg.attacker.example:5432"))
            #expect(destination.contains("bastion.example.com:2222"))
        }

        @Test("A connection name cannot add lines to the prompt")
        func promptKeepsTheNameOnOneLine() {
            var connection = importedFromAttacker()
            connection.name = "Staging\n\nTablePro verified this server."

            let message = EnvVarReferencePrompt.message(for: EnvVarReferenceConsent.question(for: connection))

            #expect(!message.contains("Staging\n"))
        }

        @Test("Every field a connect resolves is scanned for references")
        func scanCoversEveryResolvedField() {
            var connection = DatabaseConnection(name: "Fields", type: .postgresql)
            connection.host = "$A_HOST"
            connection.sshConfig.privateKeyPath = "${A_KEY}"
            connection.sslConfig.clientCertificatePath = "$A_CERT"
            connection.startupCommands = "SET role = $A_ROLE"
            connection.additionalFields["schema"] = "$A_FIELD"

            #expect(
                EnvVarResolver.referencedNames(in: connection)
                    == ["A_HOST", "A_KEY", "A_CERT", "A_ROLE", "A_FIELD"]
            )
        }
    }
}
