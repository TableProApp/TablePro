import Foundation

enum PasswordGenerator {
    static let defaultLength = 20

    private static let alphabet = Array("abcdefghkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    static func generate(length: Int = defaultLength) -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(length: length, using: &generator)
    }

    static func generate<G: RandomNumberGenerator>(
        length: Int,
        using generator: inout G
    ) -> String {
        guard length > 0 else { return "" }

        let bound = UInt64(alphabet.count)
        let limit = UInt64.max - (UInt64.max % bound)

        var password = ""
        password.reserveCapacity(length)

        while password.count < length {
            let value = generator.next()
            guard value < limit else { continue }
            password.append(alphabet[Int(value % bound)])
        }
        return password
    }
}
