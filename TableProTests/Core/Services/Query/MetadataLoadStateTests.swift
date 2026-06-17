@testable import TablePro
import Testing

@Suite("MetadataLoadState")
struct MetadataLoadStateTests {
    @Test("isSettled is false while idle or loading")
    func isSettledFalseForPendingStates() {
        #expect(MetadataLoadState<[String]>.idle.isSettled == false)
        #expect(MetadataLoadState<[String]>.loading.isSettled == false)
    }

    @Test("isSettled is true once loaded or failed")
    func isSettledTrueForTerminalStates() {
        #expect(MetadataLoadState<[String]>.loaded(["a"]).isSettled == true)
        #expect(MetadataLoadState<[String]>.failed("boom").isSettled == true)
    }

    @Test("value returns the payload only for loaded")
    func valueOnlyWhenLoaded() {
        #expect(MetadataLoadState<[String]>.idle.value == nil)
        #expect(MetadataLoadState<[String]>.loading.value == nil)
        #expect(MetadataLoadState<[String]>.failed("boom").value == nil)
        #expect(MetadataLoadState<[String]>.loaded(["a", "b"]).value == ["a", "b"])
    }
}
