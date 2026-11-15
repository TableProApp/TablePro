import Foundation
@testable import TableProMobile
import Testing

struct ImportFieldMappingTests {
    private let fields = ["id", "Name", "email"]
    private let columns = ["id", "name", "created_at"]

    private func mappedColumns(_ mapping: ImportFieldMapping) -> [String?] {
        mapping.rows.map { $0.choice.mappedColumn }
    }

    @Test("By default each field goes to the column of its name, in any case, and the rest are not imported")
    func defaultsByName() {
        var mapping = ImportFieldMapping()
        mapping.load(fields: fields, columns: columns, saved: [:], keepingChoices: false)

        #expect(mappedColumns(mapping) == ["id", "name", nil])
        #expect(mapping.columnMapping == ["id": "id", "Name": "name"])
        #expect(mapping.showsSavedMapping == false)
        #expect(mapping.overrides.isEmpty)
    }

    @Test("Match by Position pairs fields and columns in order, and Match by Name puts the names back")
    func byPositionThenName() {
        var mapping = ImportFieldMapping()
        mapping.load(fields: ["a", "b", "c", "d"], columns: columns, saved: [:], keepingChoices: false)

        mapping.matchByPosition()
        #expect(mappedColumns(mapping) == ["id", "name", "created_at", nil])

        mapping.matchByName()
        #expect(mappedColumns(mapping) == [nil, nil, nil, nil])
    }

    @Test("A mapping saved for the table comes back, and only departures from the name match are saved")
    func savedMappingRestores() {
        var mapping = ImportFieldMapping()
        mapping.load(
            fields: fields, columns: columns, saved: ["email": .column("created_at"), "Name": .skip],
            keepingChoices: false
        )

        #expect(mappedColumns(mapping) == ["id", nil, "created_at"])
        #expect(mapping.showsSavedMapping)
        #expect(mapping.overrides == ["email": .column("created_at"), "Name": .skip])

        mapping.matchByName()
        #expect(mapping.canUseSavedMapping)
        mapping.useSavedMapping()
        #expect(mappedColumns(mapping) == ["id", nil, "created_at"])
    }

    @Test("Reading the same table again keeps what was chosen in the sheet")
    func reloadKeepsChoices() {
        var mapping = ImportFieldMapping()
        mapping.load(fields: fields, columns: columns, saved: [:], keepingChoices: false)
        mapping.map("Name", to: nil)
        mapping.map("email", to: "created_at")

        mapping.load(fields: fields, columns: columns, saved: [:], keepingChoices: true)
        #expect(mappedColumns(mapping) == ["id", nil, "created_at"])

        mapping.load(fields: fields, columns: columns, saved: [:], keepingChoices: false)
        #expect(mappedColumns(mapping) == ["id", "name", nil])
    }

    @Test("Two fields sent to one column are caught")
    func oneColumnTwice() {
        var mapping = ImportFieldMapping()
        mapping.load(fields: fields, columns: columns, saved: [:], keepingChoices: false)
        #expect(mapping.mapsOneColumnTwice == false)

        mapping.map("email", to: "id")
        #expect(mapping.mapsOneColumnTwice)
        #expect(mapping.hasMappedField)
    }
}
