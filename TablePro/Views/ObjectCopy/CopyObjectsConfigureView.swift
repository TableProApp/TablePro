//
//  CopyObjectsConfigureView.swift
//  TablePro
//
//  The first step: where the copy goes, what it carries, and which objects.
//

import SwiftUI

internal struct CopyObjectsConfigureView: View {
    @Bindable internal var session: ObjectCopySession
    @Binding internal var isChoosingTarget: Bool

    internal var body: some View {
        HStack(spacing: 0) {
            settings
                .frame(width: 320)
                .padding(20)
            Divider()
            CopyObjectsListView(session: session)
                .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            destinationSection
            contentSection
            existingSection
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var destinationSection: some View {
        switch session.mode {
        case .copyTo:
            labelled(String(localized: "Copy to")) {
                Button {
                    isChoosingTarget = true
                } label: {
                    HStack {
                        Text(session.target?.qualifiedDescription ?? DatabaseEndpointSide.target.placeholderTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("copy-objects-target")
                .popover(isPresented: $isChoosingTarget, arrowEdge: .bottom) {
                    DatabaseEndpointPicker(
                        side: .target,
                        current: session.target,
                        onPick: { session.target = $0 },
                        dismiss: { isChoosingTarget = false }
                    )
                }
            }
        case .duplicateDatabase:
            labelled(String(localized: "New database")) {
                TextField(String(localized: "Name"), text: $session.newDatabaseName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("copy-objects-new-database-name")
            }
            if let spec = session.createDatabaseForm {
                CreateDatabaseOptionsView(spec: spec, values: $session.newDatabaseValues)
            }
        }
    }

    private var contentSection: some View {
        labelled(String(localized: "Copy")) {
            Picker("", selection: $session.content) {
                ForEach(ObjectCopyContent.allCases, id: \.self) { content in
                    Text(content.displayName).tag(content)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier("copy-objects-content")
        }
    }

    private var existingSection: some View {
        labelled(String(localized: "If the object is already there")) {
            Picker("", selection: $session.existingPolicy) {
                ForEach(ObjectCopyExistingPolicy.allCases, id: \.self) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("copy-objects-existing-policy")
            Text(existingPolicyExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var existingPolicyExplanation: String {
        switch session.existingPolicy {
        case .skip:
            return String(localized: "The target keeps what it has and the object is left out.")
        case .replace:
            return session.content.includesStructure
                ? String(localized: "The target's object is dropped and built again from the source.")
                : String(localized: "The target's rows are removed before the source's are written.")
        case .appendData:
            return String(localized: "The target keeps its structure and its rows, and the source's rows are added.")
        }
    }

    @ViewBuilder
    private func labelled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
