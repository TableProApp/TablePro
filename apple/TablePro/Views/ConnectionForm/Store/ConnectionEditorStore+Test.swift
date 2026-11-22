//
//  ConnectionEditorStore+Test.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os
import TableProPluginKit
import TableProSSHConfig
import TableProSSHTransport

enum ConnectionTestState: Equatable {
    case idle
    case running
    case succeeded(ConnectionTestSuccess)
    case failed(ConnectionTestFailure)
}

struct ConnectionTestSuccess: Equatable {
    let typeName: String
    let serverVersion: String?
    let elapsedMilliseconds: Int
    let warning: String?

    var summary: String {
        if let serverVersion, !serverVersion.isEmpty {
            return String(
                format: String(localized: "Connected to %1$@ %2$@ in %3$lld ms"),
                typeName, serverVersion, Int64(elapsedMilliseconds)
            )
        }
        return String(format: String(localized: "Connected to %1$@ in %2$lld ms"), typeName, Int64(elapsedMilliseconds))
    }
}

enum ConnectionTestFailureStep: Equatable {
    case tunnel(ConnectionTunnelKind)
    case tls
    case authentication
    case network
    case other

    var title: String {
        switch self {
        case .tunnel(let kind): return kind.displayName
        case .tls: return String(localized: "TLS")
        case .authentication: return String(localized: "Authentication")
        case .network: return String(localized: "Network")
        case .other: return String(localized: "Connection")
        }
    }
}

struct ConnectionTestFailure: Equatable {
    let step: ConnectionTestFailureStep
    let message: String
    let recoverySuggestion: String?
    let recoveryAction: ConnectionRecoveryAction?
    let testedConnection: DatabaseConnection?

    var summary: String {
        String(format: String(localized: "%@ failed"), step.title)
    }
}

// What a test wrote under its throwaway id, so cleanup deletes exactly that whatever the type is by then.
struct TestSecretReceipt: Equatable {
    let testId: UUID
    var items: [SecretWritePlan.Item] = []
}

struct TestRun {
    let id: UUID
    let testId: UUID
    let fingerprint: ConnectionEditorEngine.TestFingerprint
    var task: Task<Void, Never>?
}

extension ConnectionEditorStore {
    var isTesting: Bool { testState == .running }

    // The record Save would write, under a throwaway id: same draft, same base, same merge.
    func testRecord(testId: UUID) -> DatabaseConnection {
        let edits = ConnectionEditorEngine.edits(draft, traits, originalTraits: originalTraits, context)
        if !isNew, let fresh = storage.loadConnection(id: connectionId) {
            return edits.applied(to: ConnectionEditorEngine.record(fresh, reassignedTo: testId), since: baselineEdits)
        }
        return edits.applied(to: DatabaseConnection(id: testId, name: ""))
    }

    func test() {
        guard canTest else { return }
        let runId = UUID()
        let testId = UUID()
        let record = testRecord(testId: testId)
        // A linked profile owns the decision, so a profile set to ask every time asks here too.
        let prompts = ConnectionCredentialResolver.promptsForPassword(record)
        let password = draft.credentials.password
        let receipt = persistTestSecrets(for: testId, prompts: prompts)
        pendingTestReceipts[testId] = receipt

        let context = TestContext(
            runId: runId,
            record: record,
            password: password,
            prompts: prompts,
            sshPassword: draft.usesSSHServer && draft.ssh.profileId == nil ? draft.ssh.password : nil,
            displayName: draft.name.isEmpty ? draft.host : draft.name,
            isAPIToken: traits.connectionMode == .apiOnly,
            signInFields: draft.fieldValues,
            typeName: traits.displayName
        )
        testState = .running
        var run = TestRun(
            id: runId,
            testId: testId,
            fingerprint: ConnectionEditorEngine.testFingerprint(draft, traits, originalTraits: originalTraits, self.context)
        )
        run.task = Task { [weak self] in
            await self?.runTest(context)
        }
        testRun = run
    }

    func cancelTest() {
        testRun?.task?.cancel()
        testRun = nil
        if testState == .running {
            testState = .idle
        }
    }

    // A result belongs to the settings it was earned on; any edit to those settings clears it.
    func invalidateStaleTestResult() {
        switch testState {
        case .succeeded, .failed:
            break
        case .idle, .running:
            return
        }
        guard let fingerprint = lastTestedFingerprint,
              fingerprint != ConnectionEditorEngine.testFingerprint(draft, traits, originalTraits: originalTraits, context)
        else { return }
        testState = .idle
    }

    struct TestContext {
        let runId: UUID
        let record: DatabaseConnection
        let password: String
        let prompts: Bool
        let sshPassword: String?
        let displayName: String
        let isAPIToken: Bool
        let signInFields: [String: String]
        let typeName: String
    }

    private func isCurrent(_ runId: UUID) -> Bool {
        testRun?.id == runId
    }

    private func runTest(_ context: TestContext) async {
        let testId = context.record.id
        guard await authorizeExtensionsForTest(testConnectionId: testId) else {
            endRun(context, testId: testId, state: .idle)
            return
        }
        var passwordOverride: String?
        if context.prompts {
            if context.password.isEmpty {
                passwordOverride = await PasswordPromptHelper.prompt(
                    connectionName: context.displayName,
                    isAPIToken: context.isAPIToken,
                    window: window ?? NSApp.keyWindow
                )
            } else {
                passwordOverride = context.password
            }
            guard passwordOverride != nil else {
                endRun(context, testId: testId, state: .idle)
                return
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        do {
            // No sign-in consent: the person is looking at the settings Test signs in with.
            let result = try await services.databaseManager.testConnection(
                context.record,
                sshPassword: context.sshPassword,
                passwordOverride: passwordOverride
            )
            let elapsed = start.duration(to: clock.now)
            let milliseconds = Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            if result.succeeded {
                if let warning = result.warning {
                    AccessibilityAnnouncement.post(String(format: String(localized: "Connected with a warning. %@"), warning))
                }
                endRun(context, testId: testId, state: .succeeded(ConnectionTestSuccess(
                    typeName: context.typeName,
                    serverVersion: result.serverVersion,
                    elapsedMilliseconds: milliseconds,
                    warning: result.warning
                )))
            } else {
                endRun(context, testId: testId, state: .failed(ConnectionTestFailure(
                    step: .other,
                    message: String(localized: "Connection test failed"),
                    recoverySuggestion: nil,
                    recoveryAction: nil,
                    testedConnection: context.record
                )))
            }
        } catch is CancellationError {
            endRun(context, testId: testId, state: .idle)
        } catch {
            await routeTestFailure(error, context: context)
        }
    }

    // Cleanup always runs; the state lands only for the run still current, and only on the settings it tested.
    private func endRun(_ context: TestContext, testId: UUID, state: ConnectionTestState) {
        if let receipt = pendingTestReceipts[testId] {
            cleanupTestSecrets(receipt)
        }
        guard isCurrent(context.runId), let run = testRun else { return }
        testRun = nil
        lastTestedFingerprint = run.fingerprint
        let current = ConnectionEditorEngine.testFingerprint(draft, traits, originalTraits: originalTraits, self.context)
        testState = run.fingerprint == current ? state : .idle
    }

    // The existing routing: sign-in offer, plugin install, plugin diagnostic, then an inline failure naming its step.
    private func routeTestFailure(_ error: Error, context: TestContext) async {
        let testId = context.record.id
        if let provider = ConnectionSignInRegistry.provider(for: error, fields: context.signInFields) {
            endRun(context, testId: testId, state: .idle)
            guard !isClosing else { return }
            if await ConnectionSignInPrompt.offer(provider, for: error, fields: context.signInFields, window: window ?? NSApp.keyWindow) {
                test()
            }
            return
        }
        if case PluginError.pluginNotInstalled = error {
            endRun(context, testId: testId, state: .idle)
            pluginInstallConnection = context.record
            return
        }
        if let item = PluginDiagnosticItem.classify(error: error, connection: context.record, username: context.record.username) {
            endRun(context, testId: testId, state: .idle)
            pluginDiagnostic = item
            return
        }
        endRun(context, testId: testId, state: .failed(Self.failure(for: error, connection: context.record)))
    }

    static func failure(for error: Error, connection: DatabaseConnection) -> ConnectionTestFailure {
        let step = failureStep(for: error, transport: connection.activeTunnelKind)
        if let action = ConnectionFailureClassifier.recoveryAction(for: error), action != .editConnection {
            let info = ConnectionFailureClassifier.info(for: error)
            return ConnectionTestFailure(
                step: step,
                message: [info.message, info.failureReason].compactMap { $0 }.joined(separator: "\n\n"),
                recoverySuggestion: info.recoverySuggestion,
                recoveryAction: action,
                testedConnection: connection
            )
        }
        return ConnectionTestFailure(
            step: step,
            message: SSLHandshakeError.formatted(error),
            recoverySuggestion: nil,
            recoveryAction: nil,
            testedConnection: connection
        )
    }

    static func failureStep(for error: Error, transport: ConnectionTunnelKind?) -> ConnectionTestFailureStep {
        switch error {
        case is SSHTunnelError:
            return .tunnel(transport ?? .ssh)
        case is CloudflareTunnelError:
            return .tunnel(.cloudflare)
        case is CloudSQLProxyError:
            return .tunnel(.cloudSQLProxy)
        case is SOCKSProxyError:
            return .tunnel(.socksProxy)
        case is TunnelCommandError:
            return .tunnel(.tunnelCommand)
        case is ConnectionTunnelError:
            return .tunnel(transport ?? .ssh)
        case is SSLHandshakeError, is SSLModeNotSupportedError:
            return .tls
        case is LocalNetworkAccessError, is ConnectionTimeoutError, is URLError:
            return .network
        default:
            break
        }
        if ConnectionFailureClassifier.isAuthenticationFailure(error) {
            return .authentication
        }
        let domain = (error as NSError).domain
        if domain == NSPOSIXErrorDomain || domain == NSURLErrorDomain {
            return .network
        }
        return .other
    }

    func performTestRecovery() {
        guard case .failed(let failure) = testState,
              let action = failure.recoveryAction,
              let connection = failure.testedConnection
        else { return }
        ConnectionRecoveryPerformer.perform(action, for: connection)
    }

    // Test loads extensions for real, so it clears the approval a connect does, lent to the throwaway id.
    private func authorizeExtensionsForTest(testConnectionId: UUID) async -> Bool {
        let approvals = LoadableExtensionApprovalStore.shared
        let ownerId = isNew ? testConnectionId : connectionId
        approvals.approve(editedExtensions, for: ownerId)
        let owner = testRecord(testId: ownerId)
        guard await LoadableExtensionPrompt.confirmIfNeeded(for: owner, approvals: approvals) else { return false }
        if ownerId != testConnectionId {
            approvals.copyApprovals(from: ownerId, to: testConnectionId)
        }
        return true
    }

    // A test's copies never leave this Mac, whatever the password sync setting says.
    private func persistTestSecrets(for testId: UUID, prompts: Bool) -> TestSecretReceipt {
        var receipt = TestSecretReceipt(testId: testId)
        func write(_ item: SecretWritePlan.Item, _ value: String) {
            writeSecret(item, value: value, for: testId)
            receipt.items.append(item)
        }
        let draft = ConnectionEditorEngine.normalized(self.draft, traits)
        _ = storage.stagingSecretEdits(for: testId, deviceOnly: true) {
            if !draft.credentials.password.isEmpty, !prompts {
                write(.password, draft.credentials.password)
            }
            if draft.usesSSHServer, draft.ssh.profileId == nil {
                let ssh = draft.ssh
                if (ssh.authMethod == .password || ssh.authMethod == .keyboardInteractive) && !ssh.password.isEmpty {
                    write(.sshPassword, ssh.password)
                }
                if ssh.authMethod == .privateKey && !ssh.keyPassphrase.isEmpty {
                    write(.sshKeyPassphrase, ssh.keyPassphrase)
                }
                if ssh.totpMode == .autoGenerate && !ssh.totpSecret.isEmpty {
                    write(.totpSecret, ssh.totpSecret)
                }
            }
            if !draft.ssl.clientKeyPassphrase.isEmpty,
               !draft.ssl.clientKeyPath.trimmingCharacters(in: .whitespaces).isEmpty {
                write(.sslClientKeyPassphrase, draft.ssl.clientKeyPassphrase)
            }
            if draft.transport == .cloudflare, draft.cloudflare.authMethod == .serviceToken {
                write(.cloudflareTokenId, draft.cloudflare.serviceTokenId)
                write(.cloudflareTokenSecret, draft.cloudflare.serviceTokenSecret)
            }
            if draft.transport == .cloudSQLProxy, draft.cloudSQLProxy.authMode == .serviceAccountKey,
               draft.cloudSQLProxy.hasServiceAccountKey {
                write(.cloudSQLServiceAccountKey, draft.cloudSQLProxy.serviceAccountKeyJSON)
            }
            if draft.transport == .socksProxy, !draft.socksProxy.password.isEmpty {
                write(.socksPassword, draft.socksProxy.password)
            }
            for field in traits.fields where field.isSecure {
                if let value = draft.fieldValues[field.id], !value.isEmpty {
                    write(.pluginField(field.id), value)
                }
            }
        }
        return receipt
    }

    func cleanupTestSecrets(_ receipt: TestSecretReceipt) {
        for item in receipt.items {
            deleteSecret(item, for: receipt.testId)
        }
        LoadableExtensionApprovalStore.shared.revoke(for: [receipt.testId])
        pendingTestReceipts.removeValue(forKey: receipt.testId)
    }
}
