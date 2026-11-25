import Foundation

// The iOS app's wording for what the account's calls can end with. A license key and an offline file are the Mac's.
nonisolated extension AccountError {
    // Nil when there is nothing to say: the person closed the sign-in sheet or declined on the confirmation page.
    var mobileDescription: String? {
        switch self {
        case .canceled, .oauth("access_denied", _):
            return nil
        case .network:
            return String(localized: "Could not reach the server. Check your internet connection and try again.")
        case .oauth("temporarily_unavailable", _):
            return String(localized: "The server is busy. Try again in a few minutes.")
        case .signedOut:
            return String(localized: "You were signed out. Sign in again.")
        case .server(_, "offline_file_active"):
            return String(localized: "This device has a valid offline file, so it keeps its license slot until the file expires.")
        case .server(_, "not_found"):
            return String(localized: "This device was already removed.")
        case .server(let status, _) where status > 0:
            return String(format: String(localized: "Something went wrong (error %d). Try again in a moment."), status)
        case .server:
            return String(localized: "The server refused the request. Try again in a moment.")
        case .oauth, .invalidResponse, .offlineFileRejected:
            return String(localized: "Could not read the server response. Try again in a moment.")
        case .otherIssuer:
            return String(localized: "Could not confirm the sign-in came from the server TablePro asked. Sign in again.")
        case .companyServer(.invalidAddress):
            return String(localized: "Enter the server's https address, such as https://tablepro.example.com.")
        case .companyServer(.notATableProServer):
            return String(localized: "This address does not answer as a TablePro server. Check it with your administrator.")
        case .companyServer(.licenseMissing):
            return String(localized: "This server has no TablePro license installed. Ask your administrator to install one.")
        case .companyServer(.licenseInvalid):
            return String(localized: "This server's TablePro license is not valid for this server. Ask your administrator.")
        case .companyServer(.managed):
            return String(localized: "Your organization manages which server TablePro signs in to.")
        case .companyServer(.unsupported):
            return String(localized: "Your organization's server does not take this request.")
        case .signOutFirst:
            return String(localized: "Sign out first, then sign in to the other account or server.")
        }
    }
}
