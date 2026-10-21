import Foundation
import os
import TableProDatabase
import TableProGoogleCloud
import TableProModels
import TableProPluginKit

extension ConnectionFormViewModel {
    private static let iamLogger = Logger(subsystem: "com.TablePro", category: "ConnectionFormViewModel")

    var iamMethods: [IAMSignIn] {
        IAMSignIn.methods(for: type)
    }

    var offersIAM: Bool {
        !iamMethods.isEmpty
    }

    var signsInWithIAM: Bool {
        offersIAM && iam.method != nil
    }

    var iamAWSService: IAMSignIn.AWSService? {
        IAMSignIn.engine(for: type)?.awsService
    }

    // Like a tunnel turned off, fields typed under a method that is then turned off are not saved.
    var iamOptions: ConnectionFormEdits.IAMOptions? {
        guard offersIAM else { return nil }
        let current = iam.options
        guard current.method == nil, var kept = baseline?.edits.iam else { return current }
        kept.method = nil
        return kept
    }

    // Secrets follow the password rule: an empty field keeps what is stored. The session token is
    // optional, so clearing it deletes it, and the device item is written as the form holds it.
    var iamSecretsAfterSave: ConnectionIAMSecrets {
        let stored = storedSecrets.iam
        let typed = iam.secrets
        var result = stored
        switch offersIAM ? iam.method : nil {
        case .awsAccessKey:
            if !typed.secretAccessKey.isEmpty { result.secretAccessKey = typed.secretAccessKey }
            result.sessionToken = typed.sessionToken
        case .googleServiceAccount:
            if !typed.serviceAccountKey.isEmpty { result.serviceAccountKey = typed.serviceAccountKey }
        case .awsProfile:
            result.device.accessKeyId = typed.device.accessKeyId
            result.device.secretAccessKey = typed.device.secretAccessKey
            result.device.sessionToken = typed.device.sessionToken
        case .awsSSO:
            result.device.ssoStartUrl = typed.device.ssoStartUrl
            result.device.ssoRegion = typed.device.ssoRegion
            result.device.ssoAccountId = typed.device.ssoAccountId
            result.device.ssoRoleName = typed.device.ssoRoleName
        case .googleApplicationDefault:
            result.device.serviceAccountKey = typed.device.serviceAccountKey
        case nil:
            break
        }
        return result
    }

    var iamSecretWrites: ConnectionIAMSecretWrites {
        let stored = storedSecrets.iam
        let after = iamSecretsAfterSave
        return ConnectionIAMSecretWrites(
            secretAccessKey: after.secretAccessKey == stored.secretAccessKey ? nil : after.secretAccessKey,
            sessionToken: after.sessionToken == stored.sessionToken ? nil : after.sessionToken,
            serviceAccountKey: after.serviceAccountKey == stored.serviceAccountKey ? nil : after.serviceAccountKey,
            device: after.device == stored.device ? nil : after.device
        )
    }

    // Test Connection runs under its own id, so the secrets the mint reads move to that id.
    func iamTestSecrets(for connectionId: UUID) -> [String: String] {
        guard signsInWithIAM else { return [:] }
        let values = iamSecretsAfterSave
        var secrets: [String: String] = [:]
        let typed: [(ConnectionSecretKind, String)] = [
            (.awsSecretAccessKey, values.secretAccessKey),
            (.awsSessionToken, values.sessionToken),
            (.gcpServiceAccountKey, values.serviceAccountKey)
        ]
        for (kind, value) in typed where !value.isEmpty {
            secrets[kind.account(for: connectionId)] = value
        }
        let scratch = EphemeralSecureStore()
        let deviceAccount = DeviceIAMCredentials.account(for: connectionId)
        do {
            try values.device.save(for: connectionId, to: scratch)
            if let encoded = try scratch.retrieve(forKey: deviceAccount) {
                secrets[deviceAccount] = encoded
            }
        } catch {
            Self.iamLogger.error("Encoding the device sign-in settings failed: \(error.localizedDescription, privacy: .public)")
        }
        return secrets
    }

    // MARK: - Service Account Key

    var activeServiceAccountKey: String {
        switch iam.method {
        case .googleServiceAccount: iam.secrets.serviceAccountKey
        case .googleApplicationDefault: iam.secrets.device.serviceAccountKey
        default: ""
        }
    }

    var serviceAccountKeyStatus: String {
        guard !activeServiceAccountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Not set")
        }
        do {
            _ = try GoogleServiceAccountKey.parse(fieldValue: activeServiceAccountKey, readFile: { _ in nil })
            return String(localized: "Saved")
        } catch GoogleAuthError.credentialFileUnreadable {
            return String(localized: "File on the Mac")
        } catch {
            return String(localized: "Not valid")
        }
    }

    static func serviceAccountKeyProblem(_ text: String) -> String? {
        do {
            _ = try GoogleServiceAccountKey.parse(fieldValue: text, readFile: { _ in nil })
            return nil
        } catch GoogleAuthError.credentialFileUnreadable {
            return String(localized: "Paste the contents of the JSON key. A file path cannot be read on this device.")
        } catch GoogleAuthError.credentialIsPEM {
            return String(localized: "Paste the whole JSON key, not the private key alone.")
        } catch let error as GoogleAuthError {
            return GoogleAuthErrorMessages.message(for: error)
        } catch {
            return error.localizedDescription
        }
    }

    func adoptServiceAccountKey(_ text: String) {
        switch iam.method {
        case .googleServiceAccount: iam.secrets.serviceAccountKey = text
        case .googleApplicationDefault: iam.secrets.device.serviceAccountKey = text
        default: break
        }
    }

    func removeDeviceServiceAccountKey() {
        iam.secrets.device.serviceAccountKey = ""
    }

    func importServiceAccountKeyFile(_ result: Result<[URL], any Error>) {
        let url: URL
        switch result {
        case .success(let urls):
            guard let first = urls.first else { return }
            url = first
        case .failure(let error):
            iam.serviceAccountKeyFileError = error.localizedDescription
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            iam.serviceAccountKeyFileError = String(localized: "TablePro could not read that file.")
            return
        }
        if let problem = Self.serviceAccountKeyProblem(text) {
            iam.serviceAccountKeyFileError = problem
            return
        }
        adoptServiceAccountKey(text)
    }

    func dismissServiceAccountKeyFileError() {
        iam.serviceAccountKeyFileError = nil
    }

    // MARK: - IAM Identity Center

    var identityCenterSetup: AWSSSOSignIn.Setup? {
        let startUrl = iam.secrets.device.ssoStartUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let region = iam.secrets.device.ssoRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !startUrl.isEmpty, !region.isEmpty else { return nil }
        return AWSSSOSignIn.Setup(startUrl: startUrl, region: region)
    }

    func requestIdentityCenterSignIn() {
        iam.identityCenter.request = IdentityCenterSetupState.Request(kind: .signIn)
    }

    func selectIdentityCenterAccount(_ accountId: String) {
        guard accountId != iam.secrets.device.ssoAccountId else { return }
        iam.secrets.device.ssoAccountId = accountId
        iam.secrets.device.ssoRoleName = ""
        iam.identityCenter.roles = []
        iam.identityCenter.request = accountId.isEmpty
            ? nil
            : IdentityCenterSetupState.Request(kind: .roles(accountId: accountId))
    }

    // The view runs this from `.task(id:)`, so a newer request or closing the form cancels it.
    func runIdentityCenterRequest() async {
        guard let request = iam.identityCenter.request else { return }
        defer {
            if iam.identityCenter.request == request {
                iam.identityCenter.activity = .idle
                iam.identityCenter.request = nil
            }
        }
        iam.identityCenter.error = nil
        do {
            switch request.kind {
            case .signIn:
                try await signInToIdentityCenter()
            case .roles(let accountId):
                try await loadIdentityCenterRoles(accountId: accountId)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            iam.identityCenter.error = error.localizedDescription
        }
    }

    private func signInToIdentityCenter() async throws {
        guard let setup = identityCenterSetup else { return }
        iam.identityCenter.activity = .signingIn
        let tokens = AWSSSOTokenStore()
        try await AWSSSOSignIn.method(setup, tokens: tokens).signIn(prompts, prompts.generation)
        guard let token = tokens.token(startUrl: setup.startUrl) else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        let accounts = try await AWSSSOPortal.listAccounts(region: setup.region, accessToken: token.accessToken)
        try Task.checkCancellation()
        iam.identityCenter.accounts = accounts
        let saved = iam.secrets.device.ssoAccountId
        if !accounts.contains(where: { $0.accountId == saved }) {
            iam.secrets.device.ssoAccountId = accounts.count == 1 ? accounts[0].accountId : ""
            iam.secrets.device.ssoRoleName = ""
        }
        let accountId = iam.secrets.device.ssoAccountId
        guard !accountId.isEmpty else { return }
        try await loadIdentityCenterRoles(accountId: accountId)
    }

    private func loadIdentityCenterRoles(accountId: String) async throws {
        guard let setup = identityCenterSetup,
              let token = AWSSSOTokenStore().token(startUrl: setup.startUrl) else { return }
        iam.identityCenter.activity = .loadingRoles
        let roles = try await AWSSSOPortal.listAccountRoles(
            region: setup.region,
            accessToken: token.accessToken,
            accountId: accountId
        )
        try Task.checkCancellation()
        guard iam.secrets.device.ssoAccountId == accountId else { return }
        iam.identityCenter.roles = roles
        let saved = iam.secrets.device.ssoRoleName
        if !roles.contains(where: { $0.roleName == saved }) {
            iam.secrets.device.ssoRoleName = roles.count == 1 ? roles[0].roleName : ""
        }
    }
}
