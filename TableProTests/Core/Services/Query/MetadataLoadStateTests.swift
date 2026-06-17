@testable import TablePro
import Testing

@Suite("MetadataLoadState")
struct MetadataLoadStateTests {
    @Test("value returns the payload only for loaded")
    func valueOnlyWhenLoaded() {
        #expect(MetadataLoadState<[String]>.idle.value == nil)
        #expect(MetadataLoadState<[String]>.loading.value == nil)
        #expect(MetadataLoadState<[String]>.failed("boom").value == nil)
        #expect(MetadataLoadState<[String]>.loaded(["a", "b"]).value == ["a", "b"])
    }
}
