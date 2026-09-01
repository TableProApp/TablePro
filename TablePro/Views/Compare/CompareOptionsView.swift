//
//  CompareOptionsView.swift
//  TablePro
//
//  Everything that changes what a comparison means, in one popover.
//
//  Changing an option here throws the previous answer away rather than adjusting
//  it. A different normalisation rule or a different tolerance is a different
//  question, so the old result is not a stale version of the new one.
//

import SwiftUI
import TableProPluginKit

internal struct CompareOptionsView: View {
    @Bindable internal var session: CompareSyncSession

    @State private var savedProfiles: [CompareSyncProfile] = []
    @State private var newProfileName = ""

    internal var body: some View {
        Form {
            objectKindsSection
            structureSection
            dataSection
            executionSection
            savedComparisonsSection
        }
        .formStyle(.grouped)
        .onAppear {
            savedProfiles = session.savedProfiles
        }
        .onChange(of: session.mode) {
            savedProfiles = session.savedProfiles
        }
        .onChange(of: session.includedKinds) {
            session.resetComparison()
        }
        .onChange(of: session.structureOptions) {
            session.resetComparison()
        }
        .onChange(of: session.dataOptions) { previous, current in
            applyDataOptionChange(from: previous, to: current)
        }
    }

    /// A tolerance or a column set changes the answer, so every summary goes. A write-direction
    /// toggle only changes which statements come out of an answer that still stands, so the script
    /// goes and the summaries stay.
    private func applyDataOptionChange(from previous: DataCompareOptions, to current: DataCompareOptions) {
        let comparisonChanged = previous.floatTolerance != current.floatTolerance
            || previous.timestampFractionalDigits != current.timestampFractionalDigits
            || previous.excludedFromComparison != current.excludedFromComparison
            || previous.keyColumns != current.keyColumns
        if comparisonChanged {
            session.clearDataSummaries()
        } else {
            session.invalidateScript()
        }
        /// These edits deliberately do not reset the comparison, so they never reach the one place
        /// the setup is written down. Without this, changing a tolerance or a write policy and
        /// closing the window brought the previous values back.
        session.rememberSetup()
    }

    // MARK: - Objects

    private var objectKindsSection: some View {
        Section {
            ForEach(CompareObjectKind.allCases, id: \.self) { kind in
                Toggle(kind.displayName, isOn: kindBinding(kind))
                    .disabled(kind == .table)
                    .accessibilityIdentifier("compare.options.kind.\(kind.rawValue)")
            }
        } header: {
            Text("Objects to Compare")
        } footer: {
            Text("Tables always take part.")
        }
    }

    private func kindBinding(_ kind: CompareObjectKind) -> Binding<Bool> {
        Binding(
            get: { session.includedKinds.contains(kind) },
            set: { included in
                guard kind != .table else { return }
                if included {
                    session.includedKinds.insert(kind)
                } else {
                    session.includedKinds.remove(kind)
                }
            }
        )
    }

    // MARK: - Structure

    private var structureSection: some View {
        Section {
            Toggle("Identifier case", isOn: $session.structureOptions.ignoreIdentifierCase)
            Toggle("Column order", isOn: $session.structureOptions.ignoreColumnOrder)
            Toggle("Whitespace in text", isOn: $session.structureOptions.ignoreWhitespaceInText)
            Toggle("Auto-increment seed", isOn: $session.structureOptions.ignoreAutoIncrementSeed)
            Toggle("Collation and character set", isOn: $session.structureOptions.ignoreCollationAndCharset)
            Toggle("Comments and owners", isOn: $session.structureOptions.ignoreCommentsAndOwners)
        } header: {
            Text("Structure Comparison")
        } footer: {
            Text("What is switched on here is ignored when two structures are compared. These drift between environments by design.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Toggle("Insert rows the target is missing", isOn: $session.dataOptions.insertMissingRows)
            Toggle("Update rows that differ", isOn: $session.dataOptions.updateDifferingRows)
            Toggle("Delete rows the source does not have", isOn: $session.dataOptions.deleteExtraRows)

            LabeledContent("Numeric tolerance") {
                TextField(
                    String(localized: "Numeric tolerance"),
                    value: $session.dataOptions.floatTolerance,
                    format: .number
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("compare.options.floatTolerance")
            }

            LabeledContent("Timestamp digits compared") {
                Stepper(value: $session.dataOptions.timestampFractionalDigits, in: 0 ... 9) {
                    Text(session.dataOptions.timestampFractionalDigits, format: .number)
                        .monospacedDigit()
                }
                .accessibilityIdentifier("compare.options.timestampDigits")
            }
        } header: {
            Text("Data Comparison")
        } footer: {
            Text("Delete is off by default, so a first run cannot remove a row from the target.")
        }
    }

    // MARK: - Execution

    private var executionSection: some View {
        Section {
            Picker("On error", selection: $session.executionSettings.errorHandling) {
                Text("Stop and roll back").tag(ImportErrorHandling.stopAndRollback)
                Text("Stop and keep what ran").tag(ImportErrorHandling.stopAndCommit)
                Text("Skip and continue").tag(ImportErrorHandling.skipAndContinue)
            }
            Toggle("Run in a transaction", isOn: $session.executionSettings.wrapInTransaction)
                .disabled(session.executionSettings.errorHandling == .skipAndContinue)
        } header: {
            Text("Execution")
        } footer: {
            if session.executionSettings.errorHandling == .skipAndContinue {
                Text("A transaction cannot be combined with skip and continue: together they would leave the target half applied.")
            }
        }
    }

    // MARK: - Saved comparisons

    /// Every saved comparison, not only the ones matching the pair on screen. The list used to be
    /// filtered by the current source and target, so a setup appeared only after both of its
    /// endpoints had been chosen by hand, which is the work loading it exists to save.
    private var savedComparisonsSection: some View {
        Section {
            if savedProfiles.isEmpty {
                Text("Nothing saved yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(savedProfiles) { profile in
                    profileRow(profile)
                }
            }
            HStack(spacing: 8) {
                TextField(String(localized: "Name"), text: $newProfileName)
                    .accessibilityIdentifier("compare.options.profileName")
                Button("Save") {
                    session.saveProfile(named: newProfileName)
                    newProfileName = ""
                    savedProfiles = session.savedProfiles
                }
                .disabled(!canSaveProfile)
                .accessibilityIdentifier("compare.options.saveProfile")
            }
        } header: {
            Text("Saved Comparisons")
        } footer: {
            Text("Loading one sets the source, the target, the mode and these options. The Comparisons button in the toolbar lists them too.")
        }
    }

    private func profileRow(_ profile: CompareSyncProfile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(scope(of: profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Load") {
                session.apply(profile)
            }
            .disabled(!session.canLoadProfile)
            .accessibilityIdentifier("compare.options.loadProfile.\(profile.id.uuidString)")
            Button("Delete", role: .destructive) {
                session.deleteProfile(profile)
                savedProfiles = session.savedProfiles
            }
            .accessibilityIdentifier("compare.options.deleteProfile.\(profile.id.uuidString)")
        }
    }

    /// The pair a saved comparison names, so a list of several can be told apart without loading
    /// one to find out which it was.
    private func scope(of profile: CompareSyncProfile) -> String {
        String(
            format: String(localized: "%1$@ → %2$@, %3$@"),
            profile.source.database, profile.target.database, profile.mode.displayName
        )
    }

    private var canSaveProfile: Bool {
        guard !session.isBusy, session.source != nil, session.target != nil else { return false }
        return !newProfileName.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
