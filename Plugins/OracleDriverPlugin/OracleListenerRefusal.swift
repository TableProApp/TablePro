import Foundation

enum OracleListenerRefusal {
    static func detail(code: Int?) -> String {
        guard let code else {
            return String(localized: "The Oracle listener refused the connection.")
        }
        if let reason = reason(forCode: code) {
            return String(format: String(localized: "%1$@ (ORA-%2$ld)."), reason, code)
        }
        return String(format: String(localized: "The Oracle listener refused the connection (ORA-%ld)."), code)
    }

    static func reason(forCode code: Int) -> String? {
        switch code {
        case 12_514:
            return String(localized: "The listener does not know the requested service name")
        case 12_505:
            return String(localized: "The listener does not know the requested SID")
        case 12_516, 12_519, 12_520:
            return String(localized: "The listener has no handler available for the requested service")
        case 12_528:
            return String(localized: "The listener is blocking new connections to the requested service")
        default:
            return nil
        }
    }
}
