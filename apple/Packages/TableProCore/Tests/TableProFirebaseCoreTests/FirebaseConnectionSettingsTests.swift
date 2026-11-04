import Foundation
@testable import TableProFirebaseCore
import Testing

struct FirebaseConnectionSettingsTests {
    @Test("A Firebase host is kept and everything around it is dropped")
    func keepsFirebaseHosts() throws {
        let american = try FirebaseConnectionSettings.parseDatabaseURL(
            "https://Shop-default-rtdb.firebaseio.com/users?x=1", emulator: false
        )
        #expect(american.absoluteString == "https://shop-default-rtdb.firebaseio.com/")
        let european = try FirebaseConnectionSettings.parseDatabaseURL(
            "https://shop.europe-west1.firebasedatabase.app", emulator: false
        )
        #expect(european.absoluteString == "https://shop.europe-west1.firebasedatabase.app/")
        let spelled = try FirebaseConnectionSettings.parseDatabaseURL(
            "https://user:pass@shop.firebaseio.com:8443/", emulator: false
        )
        #expect(spelled.absoluteString == "https://shop.firebaseio.com/")
    }

    @Test("A host that is not Firebase's is refused", arguments: [
        "https://collector.example.com/",
        "https://firebaseio.com.example.com/",
        "https://collector.example.com/.firebaseio.com",
        "http://shop.firebaseio.com/"
    ])
    func refusesOtherHosts(text: String) {
        #expect(throws: FirebaseError.self) {
            try FirebaseConnectionSettings.parseDatabaseURL(text, emulator: false)
        }
    }

    @Test("An encoded delimiter cannot end the host before the Firebase suffix", arguments: [
        "https://collector.example.com%2F.firebaseio.com",
        "https://collector.example.com%2f.firebasedatabase.app",
        "https://collector.example.com%3A8443%2F.firebaseio.com",
        "https://collector.example.com%3F.firebaseio.com",
        "https://collector.example.com%23.firebasedatabase.app",
        "https://collector.example.com%5C.firebaseio.com",
        "https://user%40collector.example.com%2F.firebaseio.com",
        "https://collector.example.com%00.firebaseio.com",
        "https://collector.example.com%09.firebaseio.com",
        "https://collector.example.com\u{FF0F}.firebaseio.com"
    ])
    func refusesEncodedDelimitersInTheHost(text: String) {
        #expect(throws: FirebaseError.self) {
            try FirebaseConnectionSettings.parseDatabaseURL(text, emulator: false)
        }
    }

    @Test("An imported Database URL cannot send Application Default Credentials to another host")
    func importedFieldsStayOnFirebaseHosts() {
        #expect(throws: FirebaseError.self) {
            try FirebaseConnectionSettings.parse(fields: [
                FirebaseFieldID.driverVariant: FirebaseVariant.realtimeDatabase.rawValue,
                FirebaseFieldID.authMethod: FirebaseAuthMethod.applicationDefault.rawValue,
                FirebaseFieldID.databaseURL: "https://collector.example.com%2F.firebaseio.com"
            ])
        }
    }

    @Test("A server's correctUrl is adopted only when its host is Firebase's")
    func correctURLStaysOnFirebaseHosts() {
        let real = Data(#"{"correctUrl": "https://shop.europe-west1.firebasedatabase.app"}"#.utf8)
        #expect(
            RealtimeDatabaseClient.correctURL(in: real)?.absoluteString
                == "https://shop.europe-west1.firebasedatabase.app/"
        )
        let crafted = Data(#"{"correctUrl": "https://collector.example.com%2F.firebaseio.com"}"#.utf8)
        #expect(RealtimeDatabaseClient.correctURL(in: crafted) == nil)
    }

    @Test("An instance the management API lists off Firebase's hosts is dropped", arguments: [
        #"{"instances":[{"databaseUrl":"https://collector.example/"}]}"#,
        #"{"instances":[{"databaseUrl":"https://collector.example.com%2F.firebaseio.com"}]}"#,
        #"{"instances":[{"databaseUrl":"http://shop-default-rtdb.firebaseio.com"}]}"#,
    ])
    func instanceListingDropsOtherHosts(listing: String) throws {
        let parsed = try FirebaseJSON.parse(listing)
        #expect(RealtimeDatabaseInstanceLister.instanceURLs(in: parsed).isEmpty)
    }

    @Test("Instances on Firebase's hosts are kept, with everything after the host dropped")
    func instanceListingKeepsFirebaseHosts() throws {
        let listing = try FirebaseJSON.parse(#"""
        {"instances":[
          {"databaseUrl":"https://shop.europe-west1.firebasedatabase.app","state":"ACTIVE"},
          {"databaseUrl":"https://shop-default-rtdb.firebaseio.com/path","state":"ACTIVE"},
          {"databaseUrl":"https://old.firebaseio.com","state":"DISABLED"}
        ]}
        """#)
        let urls = RealtimeDatabaseInstanceLister.instanceURLs(in: listing).map { $0.absoluteString }
        #expect(urls == ["https://shop.europe-west1.firebasedatabase.app/", "https://shop-default-rtdb.firebaseio.com/"])
    }
}
