import Foundation
import TableProHTTP

// The identity provider sends the SAML token to http://localhost:<port>/?token=..., with no state to check,
// so only that exact shape ends the wait and anything else is answered and ignored.
public enum SnowflakeBrowserCallback: Sendable, Equatable {
    case token(String)
    case ignore

    public static func parse(requestHead: Data) -> SnowflakeBrowserCallback {
        guard LoopbackRedirectRequest.isComplete(requestHead),
              let target = LoopbackRedirectRequest.getTarget(LoopbackRedirectRequest.text(of: requestHead)),
              let components = URLComponents(string: target),
              components.host == nil,
              components.path == "/",
              let token = LoopbackRedirectRequest.singleValue(named: "token", in: components.queryItems ?? []),
              !token.isEmpty
        else {
            return .ignore
        }
        return .token(token)
    }
}
