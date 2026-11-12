@testable import TablePro
import Testing

struct SchemaChangeTokenGateTests {
    private static func admissions(_ tokens: [String?], forgettingAfter forgetIndex: Int? = nil) -> [Bool] {
        var gate = SchemaChangeTokenGate()
        var admitted: [Bool] = []
        for (index, token) in tokens.enumerated() {
            admitted.append(gate.admits(token))
            if index == forgetIndex {
                gate.forget()
            }
        }
        return admitted
    }

    @Test("A write that leaves the schema token alone reloads nothing after the first reload")
    func unchangedTokenIsSkipped() {
        #expect(Self.admissions(["12", "12", "12"]) == [true, false, false])
    }

    @Test("A moved token reloads, and so does every event of an engine with no token")
    func movedOrMissingTokenReloads() {
        #expect(Self.admissions(["12", "13", nil, nil, "13"]) == [true, true, true, true, true])
    }

    @Test("A failed reload forgets the token, so the next write reloads again")
    func forgottenTokenReloads() {
        #expect(Self.admissions(["12", "12"], forgettingAfter: 0) == [true, true])
    }
}
