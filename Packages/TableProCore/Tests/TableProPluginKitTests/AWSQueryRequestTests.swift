import Foundation
import TableProPluginKit
import Testing

struct AWSQueryRequestTests {
    private static let credentials = AWSCredentials(
        accessKeyId: "AKIAIOSFODNN7EXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        sessionToken: nil
    )

    private static let signingDate = Date(timeIntervalSince1970: 1_780_488_000)

    private static let parameters = [
        "Action": "DescribeDBInstances",
        "Version": "2014-10-31",
        "MaxRecords": "100"
    ]

    @Test("Form body is sorted and percent encoded")
    func formBody() {
        let request = AWSQueryRequest(service: "rds", region: "us-east-1", parameters: Self.parameters)
        #expect(
            String(decoding: request.body, as: UTF8.self)
                == "Action=DescribeDBInstances&MaxRecords=100&Version=2014-10-31"
        )
    }

    @Test("Signature matches an independently computed SigV4 vector")
    func goldenSignature() throws {
        let request = AWSQueryRequest(service: "rds", region: "us-east-1", parameters: Self.parameters)
        let signed = try request.signedURLRequest(credentials: Self.credentials, now: Self.signingDate)

        #expect(signed.url?.absoluteString == "https://rds.us-east-1.amazonaws.com/")
        #expect(signed.httpMethod == "POST")
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Date") == "20260603T120000Z")
        #expect(
            signed.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260603/us-east-1/rds/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-date, "
                + "Signature=07fe45458b36fa3686cf0dd7c4075ac370325ed82238b454244e5041b7b71aed"
        )
    }

    @Test("A session token is signed and sent, and the China partition changes the host")
    func sessionTokenAndPartition() throws {
        let credentials = AWSCredentials(
            accessKeyId: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "SESSIONTOKEN"
        )
        let request = AWSQueryRequest(service: "rds", region: "cn-north-1", parameters: Self.parameters)
        let signed = try request.signedURLRequest(credentials: credentials, now: Self.signingDate)

        #expect(signed.url?.absoluteString == "https://rds.cn-north-1.amazonaws.com.cn/")
        #expect(signed.value(forHTTPHeaderField: "X-Amz-Security-Token") == "SESSIONTOKEN")
        #expect(
            signed.value(forHTTPHeaderField: "Authorization")
                == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260603/cn-north-1/rds/aws4_request, "
                + "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token, "
                + "Signature=97b51c3f90702a95083d21cd23c5221f35bc7f0493614e07dbe27f68de001d56"
        )
    }

    @Test("Signing is deterministic and changes with the payload")
    func determinism() throws {
        let request = AWSQueryRequest(service: "rds", region: "eu-west-1", parameters: Self.parameters)
        let first = try request.signedURLRequest(credentials: Self.credentials, now: Self.signingDate)
        let second = try request.signedURLRequest(credentials: Self.credentials, now: Self.signingDate)
        #expect(first.value(forHTTPHeaderField: "Authorization") == second.value(forHTTPHeaderField: "Authorization"))

        var paged = Self.parameters
        paged["Marker"] = "next"
        let other = try AWSQueryRequest(service: "rds", region: "eu-west-1", parameters: paged)
            .signedURLRequest(credentials: Self.credentials, now: Self.signingDate)
        #expect(first.value(forHTTPHeaderField: "Authorization") != other.value(forHTTPHeaderField: "Authorization"))
    }

    @Test("A mixed-case region is canonicalized once, so the scope matches the host")
    func regionCanonicalization() throws {
        let padded = AWSQueryRequest(service: "rds", region: "  US-East-1 ", parameters: Self.parameters)
        let canonical = AWSQueryRequest(service: "rds", region: "us-east-1", parameters: Self.parameters)

        #expect(padded.region == "us-east-1")
        #expect(padded.host == "rds.us-east-1.amazonaws.com")

        let signedPadded = try padded.signedURLRequest(credentials: Self.credentials, now: Self.signingDate)
        let signedCanonical = try canonical.signedURLRequest(credentials: Self.credentials, now: Self.signingDate)
        #expect(
            signedPadded.value(forHTTPHeaderField: "Authorization")
                == signedCanonical.value(forHTTPHeaderField: "Authorization")
        )
    }

    @Test("A role ARN names its partition")
    func arnPartitions() {
        #expect(AWSPartition.resolve(arn: "arn:aws:iam::111122223333:role/Admin") == .standard)
        #expect(AWSPartition.resolve(arn: "arn:aws-cn:iam::111122223333:role/Admin") == .china)
        #expect(AWSPartition.resolve(arn: "arn:aws-us-gov:iam::111122223333:role/Admin") == .govCloud)
        #expect(AWSPartition.resolve(arn: "arn:aws-iso-b:iam::111122223333:role/Admin") == .isoB)
        #expect(AWSPartition.resolve(arn: "not-an-arn") == nil)
        #expect(AWSPartition.china.defaultRegion == "cn-north-1")
    }

    @Test("Region prefixes resolve to their partition endpoint")
    func partitionHosts() {
        #expect(AWSPartition.host(service: "rds", region: "us-east-1") == "rds.us-east-1.amazonaws.com")
        #expect(AWSPartition.host(service: "rds", region: "cn-northwest-1") == "rds.cn-northwest-1.amazonaws.com.cn")
        #expect(AWSPartition.host(service: "rds", region: "us-gov-west-1") == "rds.us-gov-west-1.amazonaws.com")
        #expect(AWSPartition.host(service: "oidc", region: "us-iso-east-1") == "oidc.us-iso-east-1.c2s.ic.gov")
        #expect(AWSPartition.host(service: "portal.sso", region: "us-isob-east-1") == "portal.sso.us-isob-east-1.sc2s.sgov.gov")
        #expect(AWSPartition.host(service: "sts", region: "eu-isoe-west-1") == "sts.eu-isoe-west-1.cloud.adc-e.uk")
        #expect(AWSPartition.host(service: "sts", region: "us-isof-south-1") == "sts.us-isof-south-1.csp.hci.ic.gov")
        #expect(AWSPartition.host(service: "rds", region: "eusc-de-east-1") == "rds.eusc-de-east-1.amazonaws.eu")
        #expect(AWSPartition.resolve(region: "US-EAST-1").id == "aws")
    }

    @Test("A Query error response is parsed from its XML envelope")
    func errorParsing() throws {
        let xml = """
        <ErrorResponse xmlns="http://rds.amazonaws.com/doc/2014-10-31/">
          <Error>
            <Type>Sender</Type>
            <Code>AccessDenied</Code>
            <Message>User: arn:aws:iam::1:user/x is not authorized to perform: rds:DescribeDBInstances</Message>
          </Error>
          <RequestId>1</RequestId>
        </ErrorResponse>
        """
        let parsed = try #require(AWSQueryErrorResponse.parse(Data(xml.utf8)))
        #expect(parsed.code == "AccessDenied")
        #expect(parsed.message?.contains("rds:DescribeDBInstances") == true)
        #expect(AWSQueryErrorResponse.parse(Data("not xml".utf8)) == nil)
    }
}
