import Foundation

public struct AWSSSOAccount: Sendable, Hashable, Identifiable {
    public let accountId: String
    public let accountName: String?
    public let emailAddress: String?

    public var id: String { accountId }

    public init(accountId: String, accountName: String? = nil, emailAddress: String? = nil) {
        self.accountId = accountId
        self.accountName = accountName
        self.emailAddress = emailAddress
    }
}

public struct AWSSSOAccountRole: Sendable, Hashable, Identifiable {
    public let accountId: String
    public let roleName: String

    public var id: String { roleName }

    public init(accountId: String, roleName: String) {
        self.accountId = accountId
        self.roleName = roleName
    }
}

public enum AWSSSOPortal {
    static let pageSize = 100

    public static func listAccounts(
        region: String,
        accessToken: String,
        session: URLSession = AWSHTTP.shared
    ) async throws -> [AWSSSOAccount] {
        let accounts = try await collectPages(
            AccountsPage.self,
            path: "/assignment/accounts",
            query: [],
            region: region,
            accessToken: accessToken,
            session: session
        )
        return accounts.map {
            AWSSSOAccount(accountId: $0.accountId, accountName: $0.accountName, emailAddress: $0.emailAddress)
        }
    }

    public static func listAccountRoles(
        region: String,
        accessToken: String,
        accountId: String,
        session: URLSession = AWSHTTP.shared
    ) async throws -> [AWSSSOAccountRole] {
        let roles = try await collectPages(
            RolesPage.self,
            path: "/assignment/roles",
            query: [URLQueryItem(name: "account_id", value: accountId)],
            region: region,
            accessToken: accessToken,
            session: session
        )
        return roles.map { AWSSSOAccountRole(accountId: $0.accountId ?? accountId, roleName: $0.roleName) }
    }

    private static func collectPages<Page: PortalPage>(
        _ type: Page.Type,
        path: String,
        query: [URLQueryItem],
        region: String,
        accessToken: String,
        session: URLSession
    ) async throws -> [Page.Item] {
        var items: [Page.Item] = []
        var nextToken: String?
        var seenTokens = Set<String>()
        repeat {
            var pageQuery = query + [URLQueryItem(name: "max_result", value: String(pageSize))]
            if let nextToken {
                pageQuery.append(URLQueryItem(name: "next_token", value: nextToken))
            }
            let data = try await get(
                path: path,
                query: pageQuery,
                region: region,
                accessToken: accessToken,
                session: session
            )
            guard let page = try? JSONDecoder().decode(type, from: data) else {
                throw AWSSSOLoginError.unexpectedResponse
            }
            items.append(contentsOf: page.items)
            nextToken = page.nextToken.flatMap { $0.isEmpty ? nil : $0 }
            // A token the portal already returned would page forever.
            if let nextToken, !seenTokens.insert(nextToken).inserted {
                throw AWSSSOLoginError.unexpectedResponse
            }
        } while nextToken != nil
        return items
    }

    private static func get(
        path: String,
        query: [URLQueryItem],
        region: String,
        accessToken: String,
        session: URLSession
    ) async throws -> Data {
        let host = AWSPartition.host(service: "portal.sso", region: region)
        guard var components = URLComponents(string: "https://\(host)\(path)") else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        // URLComponents leaves + and / unescaped in a query value, and the portal reads + as a space.
        components.percentEncodedQueryItems = query.map {
            URLQueryItem(name: $0.name, value: $0.value.map(AWSSigV4.uriEncode))
        }
        guard let url = components.url else {
            throw AWSSSOLoginError.unexpectedResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accessToken, forHTTPHeaderField: "x-amz-sso_bearer_token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw AWSSSOLoginError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AWSSSOLoginError.unexpectedResponse
        }
        guard http.statusCode == 200 else {
            throw AWSSSOLogin.failure(
                status: http.statusCode,
                errorType: http.value(forHTTPHeaderField: "x-amzn-ErrorType"),
                data: data
            )
        }
        return data
    }
}

private protocol PortalPage: Decodable {
    associatedtype Item
    var items: [Item] { get }
    var nextToken: String? { get }
}

private struct AccountsPage: PortalPage {
    struct Account: Decodable {
        let accountId: String
        let accountName: String?
        let emailAddress: String?
    }

    let accountList: [Account]?
    let nextToken: String?

    var items: [Account] { accountList ?? [] }
}

private struct RolesPage: PortalPage {
    struct Role: Decodable {
        let accountId: String?
        let roleName: String
    }

    let roleList: [Role]?
    let nextToken: String?

    var items: [Role] { roleList ?? [] }
}
