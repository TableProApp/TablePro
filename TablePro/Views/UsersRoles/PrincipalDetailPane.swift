import SwiftUI
import TableProPluginKit

struct PrincipalDetailPane: View {
    @Bindable var viewModel: UsersRolesViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let principal = viewModel.selectedPrincipal {
                header(principal)
                Divider()
                content(principal)
            } else {
                ContentUnavailableView(
                    String(localized: "No Selection"),
                    systemImage: "person.2",
                    description: Text("Select a user or role to view its privileges.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(_ principal: PluginPrincipalInfo) -> some View {
        HStack(spacing: 8) {
            Label(
                principal.ref.displayName,
                systemImage: principal.isRole ? "person.2" : "person"
            )
            .font(.subheadline.weight(.medium))
            .lineLimit(1)

            if viewModel.changeManager.stage(of: principal.ref) != .unchanged {
                Text(String(localized: "Modified"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $viewModel.detailSegment) {
                ForEach(UsersRolesViewModel.DetailSegment.allCases) { segment in
                    Text(segment.title).tag(segment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("usersroles-detail-segment")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func content(_ principal: PluginPrincipalInfo) -> some View {
        switch viewModel.detailSegment {
        case .privileges:
            PrivilegeEditorPane(viewModel: viewModel)
        case .attributes:
            PrincipalAttributesForm(viewModel: viewModel, principal: principal)
        }
    }
}

struct PendingChangesBar: View {
    @Bindable var viewModel: UsersRolesViewModel

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.isResolvingDrop {
                ProgressView()
                    .controlSize(.small)
                Text("Checking owned objects…")
                    .foregroundStyle(.secondary)
            } else {
                Label(viewModel.pendingChangesTitle, systemImage: "square.and.pencil")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(String(localized: "Discard")) {
                viewModel.discardChanges()
            }
            .disabled(!viewModel.hasChanges)
            .accessibilityIdentifier("usersroles-discard")

            Button(String(localized: "Review & Apply…")) {
                viewModel.requestApply()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.hasChanges)
            .accessibilityIdentifier("usersroles-review")
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
