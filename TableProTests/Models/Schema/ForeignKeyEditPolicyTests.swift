//
//  ForeignKeyEditPolicyTests.swift
//  TablePro
//

import Foundation
@testable import TablePro
import Testing

@Suite("Foreign Key Edit Policy")
struct ForeignKeyEditPolicyTests {
    private func resolve(
        _ support: ForeignKeyEditSupport,
        kindRefusal: String? = nil,
        canEditSchema: Bool = true
    ) -> ForeignKeyEditAvailability {
        ForeignKeyEditPolicy.resolve(
            support: support,
            engineName: "Engine",
            kindRefusal: kindRefusal,
            canEditSchema: canEditSchema
        )
    }

    @Test("An engine with the statements offers the edit")
    func offersOnAlterEngines() {
        #expect(resolve(.alter) == .available(.alter))
    }

    /// A rebuild costs more than an `ALTER`, which is why the script is reviewed first, but the
    /// user is still offered the edit rather than being told to go and write SQL.
    @Test("An engine that has to recreate the table still offers the edit")
    func offersOnRebuildEngines() {
        #expect(resolve(.rebuild) == .available(.rebuild))
    }

    /// This is the reported bug. The affordance and the reason now come from one place, so an
    /// engine with no way to make the change cannot show an enabled control that fails at Save.
    @Test("An engine that cannot make the change says so instead of offering it")
    func withholdsWhenUnsupported() {
        let availability = resolve(.unsupported)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("Engine") == true)
    }

    /// The reason comes from the caller's per-kind matrix, because only that knows whether the user
    /// is looking at a view, a materialized view or a foreign table. PostgreSQL refuses
    /// `ADD CONSTRAINT … FOREIGN KEY` on all three.
    @Test("An object kind that refuses the edit is withheld with its own reason")
    func withholdsOnRefusingKinds() {
        let availability = resolve(.rebuild, kindRefusal: "A materialized view cannot have constraints.")
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason == "A materialized view cannot have constraints.")
    }

    /// Checked before the engine's own capability so a read-only engine explains that rather than
    /// naming a constraint it could not edit either way.
    @Test("An engine that cannot edit structure at all says that first")
    func withholdsWhenSchemaEditingIsOff() {
        let availability = resolve(.alter, canEditSchema: false)
        #expect(!availability.isAvailable)
        #expect(availability.unavailableReason?.contains("structure") == true)
    }

    @Test("Every reason is a sentence, never an empty string")
    func alwaysExplainsItself() {
        let withheld = [
            resolve(.unsupported),
            resolve(.rebuild, kindRefusal: "A view cannot have constraints."),
            resolve(.alter, canEditSchema: false)
        ]
        for availability in withheld {
            #expect(availability.unavailableReason?.isEmpty == false)
        }
    }
}
