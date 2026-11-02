import TableProConnectionLibrary
import Testing

struct EnvVarReferencesTests {
    @Test("Both reference forms name their variable")
    func bothFormsAreFound() {
        #expect(EnvVarReferences.names(in: "$PROD_DB_PASSWORD") == ["PROD_DB_PASSWORD"])
        #expect(EnvVarReferences.names(in: "${AWS_SECRET_ACCESS_KEY}") == ["AWS_SECRET_ACCESS_KEY"])
        #expect(
            EnvVarReferences.names(in: "pg-${REGION}.example.com:$PORT/$REGION")
                == ["REGION", "PORT"]
        )
    }

    @Test("Text that only looks like a reference names nothing", arguments: [
        "", "$$", "$1", "${1X}", "$", "${}", "${UNCLOSED", "plain text", "price: 5$"
    ])
    func nothingIsFound(text: String) {
        #expect(EnvVarReferences.names(in: text).isEmpty)
    }

    @Test("Replacing fills known names and leaves unknown ones as written")
    func replacingKeepsUnknownNames() {
        let values = ["USER": "reader", "DB": "orders"]
        let replaced = EnvVarReferences.replacing(in: "${USER}@host/$DB?x=$MISSING") { values[$0] }
        #expect(replaced == "reader@host/orders?x=$MISSING")
    }

    @Test("Replacing works past characters outside the Basic Multilingual Plane")
    func replacingAfterAstralCharacters() {
        let replaced = EnvVarReferences.replacing(in: "🐘 $NAME 🐘") { $0 == "NAME" ? "pg" : nil }
        #expect(replaced == "🐘 pg 🐘")
    }
}
