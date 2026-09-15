import SwiftUI
import TableProPluginKit

struct AWSDiscoveryConfigurationStep: View {
    @Bindable var session: AWSDiscoverySession
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var regionQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("Import from AWS")
                .font(.body.weight(.semibold))
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                profileSection
                regionSection
                authenticationSection
                if let failure = session.credentialFailure {
                    credentialFailureView(failure)
                }
            }
            .padding(16)
        }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("AWS Profile")
                .font(.subheadline)
            AWSProfileField(
                placeholder: "default",
                accessibilityIdentifier: "aws-import-profile",
                value: $session.profileName
            )
            .frame(height: 22)
            Text(profileDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var regionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Regions")
                    .font(.subheadline)
                Spacer()
                Text(selectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(String(localized: "Filter regions"), text: $regionQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            List(filteredRegions) { region in
                Toggle(isOn: binding(for: region)) {
                    HStack(spacing: 6) {
                        Text(region.displayName)
                        Text(verbatim: region.id)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)
            .frame(height: 120)
        }
    }

    private var authenticationSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(String(localized: "Authentication"), selection: $session.authenticationMode) {
                Text("AWS IAM").tag(AWSDiscoveryAuthentication.Mode.iam)
                Text("Password").tag(AWSDiscoveryAuthentication.Mode.password)
            }
            .pickerStyle(.radioGroup)
            Text(authenticationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func credentialFailureView(_ failure: AWSDiscoverySession.CredentialFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(verbatim: failure.message)
                .font(.caption)
                .lineLimit(3)
                .textSelection(.enabled)
                .help(failure.message)
            Spacer()
            if failure.canSignIn {
                Button(String(localized: "Sign In")) {
                    Task { await session.signIn() }
                }
                .controlSize(.small)
                .disabled(session.isSigningIn)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(String(localized: "Cancel")) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button(String(localized: "Continue")) { onStart() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!session.canStart)
                .accessibilityIdentifier("aws-import-continue")
        }
        .padding(12)
    }

    private var selectableRegions: [AWSRegion] {
        let known = Set(AWSRegionCatalog.all.map(\.id))
        let custom = session.selectedRegionIds
            .filter { !known.contains($0) }
            .compactMap { AWSRegionCatalog.regionOrCustom(id: $0) }
        return custom + AWSRegionCatalog.all
    }

    private var filteredRegions: [AWSRegion] {
        let query = regionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return selectableRegions }
        return selectableRegions.filter {
            $0.id.contains(query) || $0.displayName.lowercased().contains(query)
        }
    }

    private var selectionSummary: String {
        session.selectedRegionIds.isEmpty
            ? String(localized: "None selected")
            : String(format: String(localized: "%d selected"), session.selectedRegionIds.count)
    }

    private var profileDescription: String {
        switch session.profileKind {
        case .singleSignOn:
            return String(localized: "Signs in with IAM Identity Center.")
        case .assumeRole:
            return String(localized: "Assumes a role from its source profile.")
        case .accessKey:
            return String(localized: "Uses the access key stored in ~/.aws/credentials.")
        case .credentialProcess:
            return String(localized: "Runs the profile's credential_process command.")
        case .webIdentity:
            return String(localized: "Signs in with a web identity token, which is not supported yet.")
        case .unknown:
            return String(localized: "Pick a profile from ~/.aws/config or ~/.aws/credentials.")
        @unknown default:
            return String(localized: "Pick a profile from ~/.aws/config or ~/.aws/credentials.")
        }
    }

    private var authenticationDescription: String {
        switch session.authenticationMode {
        case .iam:
            return String(localized: "Imported connections use AWS IAM where the database has it enabled, and ask for a password where it does not.")
        case .password:
            return String(localized: "Imported connections ask for a password on first connect.")
        }
    }

    private func binding(for region: AWSRegion) -> Binding<Bool> {
        Binding(
            get: { session.selectedRegionIds.contains(region.id) },
            set: { isSelected in
                if isSelected {
                    guard !session.selectedRegionIds.contains(region.id) else { return }
                    session.selectedRegionIds.append(region.id)
                } else {
                    session.selectedRegionIds.removeAll { $0 == region.id }
                }
            }
        )
    }
}
