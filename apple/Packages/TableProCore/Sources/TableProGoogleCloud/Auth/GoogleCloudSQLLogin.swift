import Foundation

public enum GoogleCloudSQLLogin {
    // What `gcloud sql generate-login-token` and the Cloud SQL connectors ask for. It allows a database
    // sign-in and nothing else, so a token that leaks cannot call another Google API.
    public static let scopes = ["https://www.googleapis.com/auth/sqlservice.login"]
}
