// The create-database form's own rules, now that two callers share them: the
// New Database sheet and Duplicate Database.

@testable import TablePro
import TableProPluginKit
import Testing

struct CreateDatabaseFormRulesTests {
    private func option(
        _ value: String,
        subtitle: String? = nil,
        group: String? = nil
    ) -> CreateDatabaseFormSpec.Option {
        CreateDatabaseFormSpec.Option(value: value, label: value, subtitle: subtitle, group: group)
    }

    private func field(
        _ id: String,
        options: [CreateDatabaseFormSpec.Option],
        defaultValue: String?,
        visibleWhen: CreateDatabaseFormSpec.Visibility? = nil,
        groupedBy: String? = nil
    ) -> CreateDatabaseFormSpec.Field {
        CreateDatabaseFormSpec.Field(
            id: id,
            label: id,
            kind: .picker(options: options, defaultValue: defaultValue),
            visibleWhen: visibleWhen,
            groupedBy: groupedBy
        )
    }

    private func spec(
        fields: [CreateDatabaseFormSpec.Field],
        textInputs: [CreateDatabaseFormSpec.TextInput] = []
    ) -> CreateDatabaseFormSpec {
        CreateDatabaseFormSpec(fields: fields, footnote: nil, textInputs: textInputs)
    }

    private func charsetSpec() -> CreateDatabaseFormSpec {
        spec(fields: [
            field("charset", options: [option("utf8mb4"), option("latin1")], defaultValue: "utf8mb4"),
            field(
                "collation",
                options: [
                    option("utf8mb4_general_ci", group: "utf8mb4"),
                    option("utf8mb4_unicode_ci", group: "utf8mb4"),
                    option("latin1_swedish_ci", group: "latin1")
                ],
                defaultValue: "utf8mb4_general_ci",
                groupedBy: "charset"
            )
        ])
    }

    @Test func testTheDriversPreferredAnswerIsChosenFirst() {
        let values = CreateDatabaseFormRules.initialValues(for: charsetSpec())

        #expect(values["charset"] == "utf8mb4")
        #expect(values["collation"] == "utf8mb4_general_ci")
    }

    @Test func testAFieldWithNoPreferredAnswerTakesItsFirstOption() {
        let subject = spec(fields: [field("owner", options: [option("postgres")], defaultValue: nil)])

        #expect(CreateDatabaseFormRules.initialValues(for: subject)["owner"] == "postgres")
    }

    @Test func testACollationIsOnlyOfferedForTheChosenCharacterSet() {
        let offered = CreateDatabaseFormRules.filteredOptions(
            for: charsetSpec().fields[1], values: ["charset": "latin1"]
        )

        #expect(offered.map(\.value) == ["latin1_swedish_ci"])
    }

    /// Leaving a collation from the character set the user just moved away from would submit a
    /// pair the server refuses.
    @Test func testChangingTheCharacterSetResetsTheCollation() {
        let updated = CreateDatabaseFormRules.resettingGroupedFields(
            after: "charset",
            in: charsetSpec(),
            values: ["charset": "latin1", "collation": "utf8mb4_general_ci"]
        )

        #expect(updated["collation"] == "latin1_swedish_ci")
    }

    @Test func testGroupSourcesAreTheFieldsOthersAreGroupedBy() {
        #expect(CreateDatabaseFormRules.groupSourceFieldIds(in: charsetSpec()) == ["charset"])
    }

    // MARK: - Visibility

    private func conditionalSpec() -> CreateDatabaseFormSpec {
        spec(fields: [
            field("kind", options: [option("standard"), option("clone")], defaultValue: "standard"),
            field(
                "source",
                options: [option("app")],
                defaultValue: "app",
                visibleWhen: CreateDatabaseFormSpec.Visibility(fieldId: "kind", equals: "clone")
            )
        ])
    }

    @Test func testAHiddenFieldIsNotOffered() {
        let visible = CreateDatabaseFormRules.visibleFields(
            in: conditionalSpec(), values: ["kind": "standard"]
        )

        #expect(visible.map(\.id) == ["kind"])
    }

    /// A hidden field holds a stale answer rather than a chosen one.
    @Test func testAHiddenFieldIsNotSubmitted() {
        let submitted = CreateDatabaseFormRules.submissionValues(
            from: ["kind": "standard", "source": "app"], spec: conditionalSpec()
        )

        #expect(submitted == ["kind": "standard"])
    }

    @Test func testAVisibleFieldIsSubmitted() {
        let submitted = CreateDatabaseFormRules.submissionValues(
            from: ["kind": "clone", "source": "app"], spec: conditionalSpec()
        )

        #expect(submitted == ["kind": "clone", "source": "app"])
    }

    // MARK: - Required text

    @Test func testAnEmptyRequiredInputBlocksSubmission() {
        let subject = spec(
            fields: [],
            textInputs: [CreateDatabaseFormSpec.TextInput(
                id: "owner", label: "Owner", placeholder: nil, isRequired: true
            )]
        )

        #expect(CreateDatabaseFormRules.missingRequiredInput(in: subject, values: ["owner": "  "]))
        #expect(!CreateDatabaseFormRules.missingRequiredInput(in: subject, values: ["owner": "admin"]))
    }

    @Test func testAnOptionalInputDoesNotBlockSubmission() {
        let subject = spec(
            fields: [],
            textInputs: [CreateDatabaseFormSpec.TextInput(
                id: "note", label: "Note", placeholder: nil, isRequired: false
            )]
        )

        #expect(!CreateDatabaseFormRules.missingRequiredInput(in: subject, values: [:]))
    }

    @Test func testASubtitleIsAppendedToTheOptionLabel() {
        #expect(CreateDatabaseFormRules.displayLabel(for: option("utf8mb4", subtitle: "(default)")) == "utf8mb4 (default)")
    }

    @Test func testAnOptionWithNoSubtitleKeepsItsLabel() {
        #expect(CreateDatabaseFormRules.displayLabel(for: option("utf8mb4")) == "utf8mb4")
    }
}
