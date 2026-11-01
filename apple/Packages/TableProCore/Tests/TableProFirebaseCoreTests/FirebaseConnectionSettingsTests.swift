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
}
