import SwiftUI
import TableProPluginKit

struct ConnectionAuthenticationSection: View {
    @Bindable var viewModel: ConnectionFormViewModel
    var onChooseKeyFile: () -> Void
    var onPasteKey: () -> Void

    var body: some View {
        Section {
            Picker(String(localized: "Method"), selection: $viewModel.iam.method) {
                Text("Password").tag(IAMSignIn?.none)
                ForEach(viewModel.iamMethods) { method in
                    Text(method.title).tag(Optional(method))
                }
            }

            if let method = viewModel.iam.method {
                methodRows(method)
            }
        } header: {
            Text("Authentication")
        } footer: {
            switch viewModel.iam.method {
            case .awsAccessKey, .googleServiceAccount:
                Text("Keys sync to your other devices when Sync Passwords is on.")
            default:
                EmptyView()
            }
        }

        switch viewModel.iam.method {
        case .awsProfile:
            deviceAccessKeySection
        case .awsSSO:
            identityCenterSection
        case .googleApplicationDefault:
            deviceServiceAccountKeySection
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func methodRows(_ method: IAMSignIn) -> some View {
        if method.isAWS {
            TextField("AWS Region", text: $viewModel.iam.region)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
            if viewModel.iamAWSService == .elastiCache {
                TextField("Cache Name / Replication Group ID", text: $viewModel.iam.replicationGroupId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
            } else {
                TextField("RDS Endpoint (optional)", text: $viewModel.iam.rdsEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            }
        }

        switch method {
        case .awsAccessKey:
            accessKeyFields(
                accessKeyId: $viewModel.iam.accessKeyId,
                secretAccessKey: $viewModel.iam.secrets.secretAccessKey,
                sessionToken: $viewModel.iam.secrets.sessionToken
            )
        case .awsProfile, .awsSSO:
            TextField("Profile Name", text: $viewModel.iam.profileName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
        case .googleServiceAccount:
            serviceAccountKeyRow(removable: false)
        case .googleApplicationDefault:
            EmptyView()
        }
    }

    @ViewBuilder
    private func accessKeyFields(
        accessKeyId: Binding<String>,
        secretAccessKey: Binding<String>,
        sessionToken: Binding<String>
    ) -> some View {
        TextField("Access Key ID", text: accessKeyId)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
        SecureField("Secret Access Key", text: secretAccessKey)
        SecureField("Session Token (optional)", text: sessionToken)
    }

    private func serviceAccountKeyRow(removable: Bool) -> some View {
        Menu {
            Button(String(localized: "Paste")) { onPasteKey() }
            Button(String(localized: "Choose File")) { onChooseKeyFile() }
            if removable, !viewModel.activeServiceAccountKey.isEmpty {
                Button(String(localized: "Remove"), role: .destructive) {
                    viewModel.removeDeviceServiceAccountKey()
                }
            }
        } label: {
            HStack {
                Text("Service Account Key")
                Spacer()
                Text(viewModel.serviceAccountKeyStatus)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - This Device

    private var deviceAccessKeySection: some View {
        Section {
            accessKeyFields(
                accessKeyId: $viewModel.iam.secrets.device.accessKeyId,
                secretAccessKey: $viewModel.iam.secrets.device.secretAccessKey,
                sessionToken: $viewModel.iam.secrets.device.sessionToken
            )
        } header: {
            Text("Access Key for This Device")
        } footer: {
            Text("The profile is read from files on the Mac. A key added here signs in on this device only. The Mac's connection does not change.")
        }
    }

    private var deviceServiceAccountKeySection: some View {
        Section {
            serviceAccountKeyRow(removable: true)
        } header: {
            Text("Key for This Device")
        } footer: {
            Text("Application Default credentials are files on the Mac. A key added here signs in on this device only. The Mac's connection does not change.")
        }
    }

    private var identityCenterSection: some View {
        Section {
            TextField("Start URL", text: $viewModel.iam.secrets.device.ssoStartUrl)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("SSO Region", text: $viewModel.iam.secrets.device.ssoRegion)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)

            Button {
                viewModel.requestIdentityCenterSignIn()
            } label: {
                HStack {
                    Text("Sign In with IAM Identity Center")
                    if viewModel.iam.identityCenter.activity != .idle {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.identityCenterSetup == nil || viewModel.iam.identityCenter.activity == .signingIn)

            accountRows

            if let error = viewModel.iam.identityCenter.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("IAM Identity Center")
        } footer: {
            Text("These settings stay on this device. The Mac reads them from its AWS profile.")
        }
    }

    @ViewBuilder
    private var accountRows: some View {
        let device = viewModel.iam.secrets.device
        let state = viewModel.iam.identityCenter
        if state.accounts.isEmpty {
            LabeledContent("Account") {
                savedValue(device.ssoAccountId)
            }
            LabeledContent("Role") {
                savedValue(device.ssoRoleName)
            }
        } else {
            Picker(String(localized: "Account"), selection: accountSelection) {
                Text("None").tag("")
                if !device.ssoAccountId.isEmpty, !state.accounts.contains(where: { $0.accountId == device.ssoAccountId }) {
                    Text(device.ssoAccountId).tag(device.ssoAccountId)
                }
                ForEach(state.accounts) { account in
                    Text(accountTitle(account)).tag(account.accountId)
                }
            }
            Picker(String(localized: "Role"), selection: $viewModel.iam.secrets.device.ssoRoleName) {
                Text("None").tag("")
                if !device.ssoRoleName.isEmpty, !state.roles.contains(where: { $0.roleName == device.ssoRoleName }) {
                    Text(device.ssoRoleName).tag(device.ssoRoleName)
                }
                ForEach(state.roles) { role in
                    Text(role.roleName).tag(role.roleName)
                }
            }
            .disabled(device.ssoAccountId.isEmpty)
        }
    }

    private var accountSelection: Binding<String> {
        Binding(
            get: { viewModel.iam.secrets.device.ssoAccountId },
            set: { viewModel.selectIdentityCenterAccount($0) }
        )
    }

    @ViewBuilder
    private func savedValue(_ value: String) -> some View {
        if value.isEmpty {
            Text("Not set")
        } else {
            Text(value)
        }
    }

    private func accountTitle(_ account: AWSSSOAccount) -> String {
        guard let name = account.accountName, !name.isEmpty else { return account.accountId }
        return "\(name) (\(account.accountId))"
    }
}
