//
//  UserTypeDraftTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct UserTypeDraftTests {
    private let mood = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "app", enumLabels: ["sad", "ok"])
    private let address = UserDefinedTypeInfo(
        name: "address", kind: .composite, schema: "app",
        fields: [.init(name: "street", type: "text"), .init(name: "zip", type: "integer")]
    )
    private let posint = UserDefinedTypeInfo(
        name: "posint", kind: .domain, schema: "app", baseType: "integer",
        comment: "Counts", defaultValue: "1", isNotNull: false,
        constraints: [.init(name: "positive", definition: "CHECK ((VALUE > 0))", isValidated: false)]
    )

    private func staged(_ change: PluginUserDefinedTypeChange) -> StagedTypeChange {
        StagedTypeChange(change: change)
    }

    @Test("A label lands where its placement says, and a later label can be placed after it")
    func labelPlacement() {
        let glad = staged(.addEnumLabel("glad", placement: PluginEnumLabelPlacement(anchor: "ok", placesBefore: true)))
        let joy = staged(.addEnumLabel("joy", placement: PluginEnumLabelPlacement(anchor: "glad", placesBefore: false)))
        let last = staged(.addEnumLabel("meh", placement: nil))
        let projection = UserTypeDraft.project(mood, changes: [glad, joy, last])

        #expect(projection.draft.labels.map { $0.name } == ["sad", "glad", "joy", "ok", "meh"])
        #expect(projection.issues.isEmpty)
        #expect(projection.draft.labels[1].origin == .added(glad.id))
    }

    @Test("A label placed after one whose addition left the queue is reported, not applied")
    func orphanedPlacement() {
        let joy = staged(.addEnumLabel("joy", placement: PluginEnumLabelPlacement(anchor: "glad", placesBefore: false)))
        let projection = UserTypeDraft.project(mood, changes: [joy])

        #expect(projection.draft.labels.map { $0.name } == ["sad", "ok"])
        #expect(projection.issues[joy.id] != nil)
    }

    @Test("A duplicate label and a rename onto an existing label are refused")
    func duplicateLabels() {
        let duplicate = staged(.addEnumLabel("ok", placement: nil))
        let clash = staged(.renameEnumLabel(from: "sad", to: "ok"))
        let projection = UserTypeDraft.project(mood, changes: [duplicate, clash])

        #expect(projection.issues[duplicate.id] != nil)
        #expect(projection.issues[clash.id] != nil)
        #expect(projection.draft.labels.map { $0.name } == ["sad", "ok"])
    }

    @Test("A renamed label keeps its origin, so the row says what it was")
    func renamedLabel() {
        let projection = UserTypeDraft.project(mood, changes: [staged(.renameEnumLabel(from: "ok", to: "fine"))])

        #expect(projection.draft.labels.map { $0.name } == ["sad", "fine"])
        #expect(projection.draft.labels[1].isRenamed)
        #expect(projection.draft.labels[1].originalName == "ok")
    }

    @Test("Fields are added, renamed, retyped and dropped in queue order")
    func compositeFields() {
        let changes = [
            staged(.addField(PluginUserDefinedTypeField(name: "city", type: "text"))),
            staged(.renameField(from: "zip", to: "postcode")),
            staged(.changeFieldType(field: "postcode", type: "bigint")),
            staged(.dropField("street"))
        ]
        let projection = UserTypeDraft.project(address, changes: changes)

        #expect(projection.issues.isEmpty)
        #expect(projection.draft.liveFields.map { $0.name } == ["postcode", "city"])
        #expect(projection.draft.fields.first { $0.name == "postcode" }?.isRetyped == true)
        #expect(projection.draft.fields.first { $0.name == "street" }?.isDropped == true)
    }

    @Test("A field that is gone or taken is reported against the change")
    func fieldConflicts() {
        let drop = staged(.dropField("street"))
        let retypeDropped = staged(.changeFieldType(field: "street", type: "text"))
        let renameOnto = staged(.renameField(from: "zip", to: "street"))
        let projection = UserTypeDraft.project(address, changes: [drop, retypeDropped, renameOnto])

        #expect(projection.issues[drop.id] == nil)
        #expect(projection.issues[retypeDropped.id] != nil)
        #expect(projection.issues[renameOnto.id] == nil)
        #expect(projection.draft.liveFields.map { $0.name } == ["street"])
    }

    @Test("A domain's default, NULL rule and checks follow the queue")
    func domainChanges() {
        let check = staged(.addCheck(PluginUserDefinedTypeCheck(name: "small", expression: "VALUE < 100"), validatesExistingValues: true))
        let validate = staged(.validateConstraint("positive"))
        let projection = UserTypeDraft.project(posint, changes: [
            staged(.setDefault(nil)),
            staged(.setNotNull(true)),
            check,
            validate
        ])

        #expect(projection.draft.defaultValue == nil)
        #expect(projection.draft.isNotNull)
        #expect(projection.draft.constraints.map { $0.name } == ["positive", "small"])
        #expect(projection.draft.constraints[0].isValidationQueued)
        #expect(projection.issues.isEmpty)
    }

    @Test("A check named like a live constraint, or validating one already valid, is refused")
    func domainConflicts() {
        let clash = staged(.addCheck(PluginUserDefinedTypeCheck(name: "positive", expression: "true"), validatesExistingValues: true))
        let validated = UserDefinedTypeInfo(
            name: "d", kind: .domain, schema: "app", baseType: "int",
            constraints: [.init(name: "c", definition: "CHECK (true)")]
        )
        let again = staged(.validateConstraint("c"))

        #expect(UserTypeDraft.project(posint, changes: [clash]).issues[clash.id] != nil)
        #expect(UserTypeDraft.project(validated, changes: [again]).issues[again.id] != nil)
    }

    @Test("A dropped constraint frees its name for a new check")
    func dropFreesName() {
        let drop = staged(.dropConstraint("positive"))
        let readd = staged(.addCheck(PluginUserDefinedTypeCheck(name: "positive", expression: "VALUE >= 0"), validatesExistingValues: true))
        let projection = UserTypeDraft.project(posint, changes: [drop, readd])

        #expect(projection.issues.isEmpty)
        #expect(projection.draft.liveConstraints.map { $0.text } == ["VALUE >= 0"])
    }

    @Test("A change for another kind of type is refused rather than applied")
    func wrongKind() {
        let label = staged(.addEnumLabel("x", placement: nil))
        #expect(UserTypeDraft.project(address, changes: [label]).issues[label.id] != nil)
    }
}
