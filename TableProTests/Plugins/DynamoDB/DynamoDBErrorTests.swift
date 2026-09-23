import Foundation
import TableProPluginKit
import Testing

@Suite("DynamoDB errors")
struct DynamoDBErrorTests {
    struct CategoryCase: Sendable, CustomTestStringConvertible {
        let code: String
        let status: Int
        let message: String
        let category: DynamoDBServiceError.Category
        var testDescription: String { "\(code) \(status)" }

        init(_ code: String, status: Int = 400, message: String = "", _ category: DynamoDBServiceError.Category) {
            self.code = code
            self.status = status
            self.message = message
            self.category = category
        }
    }

    private static func parse(_ body: String, status: Int = 400) -> DynamoDBServiceError {
        DynamoDBServiceError.parse(body: Data(body.utf8), httpStatus: status)
    }

    @Test("The code is the part of the DynamoDB __type after the hash")
    func parsesDynamoDBNamespace() {
        let error = Self.parse(
            #"{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException","message":"The conditional request failed"}"#
        )
        #expect(error.code == "ConditionalCheckFailedException")
        #expect(error.message == "The conditional request failed")
        #expect(error.httpStatus == 400)
        #expect(error.cancellationReasons.isEmpty)
        #expect(error.isConditionalCheckFailure)
    }

    @Test("The coral validation namespace and a capitalised Message are read too")
    func parsesCoralNamespace() {
        let error = Self.parse(
            #"{"__type":"com.amazon.coral.validate#ValidationException","Message":"One or more parameter values were invalid"}"#
        )
        #expect(error.code == "ValidationException")
        #expect(error.message == "One or more parameter values were invalid")
        #expect(!error.isConditionalCheckFailure)
    }

    @Test("A lowercase message wins over a capitalised one")
    func lowercaseMessageWins() {
        let error = Self.parse(#"{"__type":"x#ValidationException","message":"lower","Message":"upper"}"#)
        #expect(error.message == "lower")
    }

    @Test("A __type with no namespace is the code as is")
    func typeWithoutNamespace() {
        #expect(Self.parse(#"{"__type":"ThrottlingException","message":"slow down"}"#).code == "ThrottlingException")
    }

    @Test("A body with no message names the error by its code")
    func missingMessageUsesCode() {
        let error = Self.parse(#"{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException"}"#)
        #expect(error.message == "ResourceNotFoundException")
    }

    @Test("A JSON body with no __type is named by its HTTP status")
    func missingTypeUsesStatus() {
        let error = Self.parse(#"{"message":"upstream failed"}"#, status: 503)
        #expect(error.code == "HTTP503")
        #expect(error.message == "upstream failed")
        #expect(error.category == .transient)
    }

    @Test("A body that is not JSON becomes an HTTP error with its size", arguments: ["<html>Bad Gateway</html>", ""])
    func nonJSONBody(_ body: String) {
        let error = Self.parse(body, status: 502)
        #expect(error.code == "HTTP502")
        #expect(error.message == String(format: String(localized: "HTTP %d with a body of %d bytes"), 502, Data(body.utf8).count))
        #expect(error.httpStatus == 502)
        #expect(error.category == .transient)
    }

    @Test("Cancellation reasons are decoded in order, with None for a reason that has no code")
    func decodesCancellationReasons() {
        let error = Self.parse(
            #"""
            {"__type":"com.amazonaws.dynamodb.v20120810#TransactionCanceledException",
             "Message":"Transaction cancelled, please refer cancellation reasons for specific reasons [None, ConditionalCheckFailed]",
             "CancellationReasons":[{"Code":"None"},{"Code":"ConditionalCheckFailed","Message":"The conditional request failed"},{}]}
            """#
        )
        #expect(error.code == "TransactionCanceledException")
        #expect(error.cancellationReasons == [
            DynamoDBCancellationReason(code: "None", message: nil),
            DynamoDBCancellationReason(code: "ConditionalCheckFailed", message: "The conditional request failed"),
            DynamoDBCancellationReason(code: "None", message: nil)
        ])
    }

    @Test(
        "Every error falls into the category that decides its retry",
        arguments: [
            CategoryCase("ProvisionedThroughputExceededException", .throttling),
            CategoryCase("ThrottlingException", .throttling),
            CategoryCase("RequestLimitExceeded", .throttling),
            CategoryCase("LimitExceededException", .throttling),
            CategoryCase("TransactionInProgressException", .throttling),
            CategoryCase("ReplicatedWriteConflictException", .throttling),
            CategoryCase("ItemCollectionSizeLimitExceededException", .throttling),
            CategoryCase("InternalServerError", status: 500, .transient),
            CategoryCase("ServiceUnavailable", status: 503, .transient),
            CategoryCase("HTTP500", status: 500, .transient),
            CategoryCase("SomethingNew", status: 500, .transient),
            CategoryCase("ExpiredTokenException", .expiredCredentials),
            CategoryCase("ExpiredToken", .expiredCredentials),
            CategoryCase(
                "InvalidSignatureException",
                message: "Signature expired: 20150830T123600Z is now earlier than 20150830T124100Z (20150830T124600Z - 5 min.)",
                .clockSkew
            ),
            CategoryCase(
                "InvalidSignatureException",
                message: "Signature not yet current: 20150830T130100Z is still later than 20150830T125100Z",
                .clockSkew
            ),
            CategoryCase("RequestTimeTooSkewed", .clockSkew),
            CategoryCase("RequestExpired", .clockSkew),
            CategoryCase(
                "InvalidSignatureException",
                message: "The request signature we calculated does not match the signature you provided.",
                .authentication
            ),
            CategoryCase("UnrecognizedClientException", message: "The security token included in the request is invalid.", .authentication),
            CategoryCase("MissingAuthenticationTokenException", .authentication),
            CategoryCase("IncompleteSignatureException", .authentication),
            CategoryCase("AccessDeniedException", message: "User is not authorized to perform: dynamodb:Scan", .fatal),
            CategoryCase("ValidationException", .fatal),
            CategoryCase("ResourceNotFoundException", .fatal),
            CategoryCase("ConditionalCheckFailedException", .fatal),
            CategoryCase("TransactionCanceledException", .fatal)
        ]
    )
    func category(_ testCase: CategoryCase) {
        let error = DynamoDBServiceError(code: testCase.code, message: testCase.message, httpStatus: testCase.status)
        #expect(error.category == testCase.category)
    }

    @Test("An authentication failure says so")
    func authenticationUserMessage() {
        let error = DynamoDBServiceError(
            code: "UnrecognizedClientException", message: "The security token included in the request is invalid.", httpStatus: 400
        )
        #expect(error.userMessage == String(
            format: String(localized: "Authentication failed: %@"), "The security token included in the request is invalid."
        ))
    }

    @Test("Access denied is reported as a DynamoDB error, not as a failed sign-in")
    func accessDeniedIsNotAuthentication() {
        let error = DynamoDBServiceError(
            code: "AccessDeniedException", message: "User is not authorized to perform: dynamodb:Scan", httpStatus: 400
        )
        #expect(error.userMessage == String(
            format: String(localized: "DynamoDB error: [%1$@] %2$@"),
            "AccessDeniedException", "User is not authorized to perform: dynamodb:Scan"
        ))
        #expect(!error.userMessage.hasPrefix(String(format: String(localized: "Authentication failed: %@"), "")))
    }

    @Test("A cancelled transaction lists each failed action by its 1-based number and skips None")
    func cancellationReasonsInUserMessage() {
        let error = DynamoDBServiceError(
            code: "TransactionCanceledException",
            message: "Transaction cancelled",
            httpStatus: 400,
            cancellationReasons: [
                DynamoDBCancellationReason(code: "None", message: nil),
                DynamoDBCancellationReason(code: "ConditionalCheckFailed", message: "The conditional request failed"),
                DynamoDBCancellationReason(code: "None", message: nil),
                DynamoDBCancellationReason(code: "ValidationException", message: nil)
            ]
        )
        let lines = error.userMessage.components(separatedBy: "\n")
        #expect(lines == [
            String(format: String(localized: "DynamoDB error: [%1$@] %2$@"), "TransactionCanceledException", "Transaction cancelled"),
            String(
                format: String(localized: "Action %1$d: %2$@%3$@"), 2, "ConditionalCheckFailed", " The conditional request failed"
            ),
            String(format: String(localized: "Action %1$d: %2$@%3$@"), 4, "ValidationException", "")
        ])
    }

    @Test("A cancelled transaction with only None reasons adds no lines")
    func noneReasonsAddNothing() {
        let error = DynamoDBServiceError(
            code: "TransactionCanceledException",
            message: "Transaction cancelled",
            httpStatus: 400,
            cancellationReasons: [DynamoDBCancellationReason(code: "None", message: nil)]
        )
        #expect(!error.userMessage.contains("\n"))
    }

    @Test("A service error describes itself with its user message")
    func serviceErrorDescription() {
        let service = DynamoDBServiceError(code: "ValidationException", message: "bad key", httpStatus: 400)
        #expect(DynamoDBError.service(service).errorDescription == service.userMessage)
    }

    @Test("A partial batch reports how many writes applied, then each failure on its own line")
    func partialBatchDescription() {
        let error = DynamoDBError.partialBatch(applied: 3, total: 5, failures: ["pk = a: throttled", "pk = b: throttled"])
        #expect(error.errorDescription == [
            String(format: String(localized: "%1$d of %2$d were applied."), 3, 5),
            "pk = a: throttled",
            "pk = b: throttled"
        ].joined(separator: "\n"))
    }

    @Test("A changed item names its key and says to refresh")
    func itemChangedDescription() {
        let error = DynamoDBError.itemChanged(key: "pk = a, sk = 3")
        #expect(error.errorDescription == String(
            format: String(localized: "The item %@ changed after it was loaded. Refresh the table and edit it again."),
            "pk = a, sk = 3"
        ))
        #expect(error.errorDescription?.contains("pk = a, sk = 3") == true)
    }

    @Test("A timeout names the seconds it waited")
    func timedOutDescription() {
        let error = DynamoDBError.timedOut(seconds: 30)
        #expect(error.errorDescription == String(
            format: String(localized: "Stopped after %d seconds, the query timeout"), 30
        ))
        #expect(error.errorDescription?.contains("30") == true)
    }

    @Test("An invalid value names its attribute unless it has none")
    func invalidValueDescription() {
        #expect(DynamoDBError.invalidValue(attribute: "", reason: "Not a number").errorDescription == "Not a number")
        #expect(DynamoDBError.invalidValue(attribute: "age", reason: "Not a number").errorDescription
            == String(format: String(localized: "%@: %@"), "age", "Not a number"))
    }
}
