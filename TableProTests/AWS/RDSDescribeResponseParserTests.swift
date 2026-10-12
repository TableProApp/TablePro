import Foundation
@testable import TablePro
import Testing

struct RDSDescribeResponseParserTests {
    static let instancesXML = """
    <DescribeDBInstancesResponse xmlns="http://rds.amazonaws.com/doc/2014-10-31/">
      <DescribeDBInstancesResult>
        <Marker>page-2</Marker>
        <DBInstances>
          <DBInstance>
            <DBInstanceIdentifier>orders</DBInstanceIdentifier>
            <Engine>postgres</Engine>
            <EngineVersion>16.3</EngineVersion>
            <DBInstanceStatus>available</DBInstanceStatus>
            <MasterUsername>postgres</MasterUsername>
            <DBName>orders</DBName>
            <PubliclyAccessible>true</PubliclyAccessible>
            <IAMDatabaseAuthenticationEnabled>true</IAMDatabaseAuthenticationEnabled>
            <Endpoint>
              <Address>orders.abc123.us-east-1.rds.amazonaws.com</Address>
              <Port>5432</Port>
              <HostedZoneId>Z2R2ITUGPM61AM</HostedZoneId>
            </Endpoint>
            <TagList>
              <Tag><Key>env</Key><Value>prod</Value></Tag>
            </TagList>
          </DBInstance>
          <DBInstance>
            <DBInstanceIdentifier>analytics-1</DBInstanceIdentifier>
            <Engine>aurora-mysql</Engine>
            <DBClusterIdentifier>analytics</DBClusterIdentifier>
            <DBInstanceStatus>available</DBInstanceStatus>
            <Endpoint>
              <Address>analytics-1.abc123.us-east-1.rds.amazonaws.com</Address>
              <Port>3306</Port>
            </Endpoint>
          </DBInstance>
          <DBInstance>
            <DBInstanceIdentifier>creating-one</DBInstanceIdentifier>
            <Engine>mysql</Engine>
            <DBInstanceStatus>creating</DBInstanceStatus>
          </DBInstance>
        </DBInstances>
      </DescribeDBInstancesResult>
    </DescribeDBInstancesResponse>
    """

    static let clustersXML = """
    <DescribeDBClustersResponse xmlns="http://rds.amazonaws.com/doc/2014-10-31/">
      <DescribeDBClustersResult>
        <DBClusters>
          <DBCluster>
            <DBClusterIdentifier>analytics</DBClusterIdentifier>
            <Engine>aurora-mysql</Engine>
            <EngineVersion>8.0.mysql_aurora.3.05.2</EngineVersion>
            <Status>available</Status>
            <DatabaseName>analytics</DatabaseName>
            <MasterUsername>admin</MasterUsername>
            <IAMDatabaseAuthenticationEnabled>true</IAMDatabaseAuthenticationEnabled>
            <Endpoint>analytics.cluster-abc123.us-east-1.rds.amazonaws.com</Endpoint>
            <ReaderEndpoint>analytics.cluster-ro-abc123.us-east-1.rds.amazonaws.com</ReaderEndpoint>
            <DBClusterMembers>
              <DBClusterMember>
                <DBInstanceIdentifier>analytics-1</DBInstanceIdentifier>
                <IsClusterWriter>true</IsClusterWriter>
              </DBClusterMember>
              <DBClusterMember>
                <DBInstanceIdentifier>analytics-2</DBInstanceIdentifier>
                <IsClusterWriter>false</IsClusterWriter>
              </DBClusterMember>
            </DBClusterMembers>
          </DBCluster>
          <DBCluster>
            <DBClusterIdentifier>serverless-pending</DBClusterIdentifier>
            <Engine>aurora-postgresql</Engine>
            <Status>creating</Status>
            <Port>5432</Port>
            <DBClusterMembers/>
          </DBCluster>
        </DBClusters>
      </DescribeDBClustersResult>
    </DescribeDBClustersResponse>
    """

    @Test("Instances parse with their endpoint, marker and optional fields")
    func instances() throws {
        let page = try #require(RDSDescribeResponseParser.parseInstances(Data(Self.instancesXML.utf8)))
        #expect(page.marker == "page-2")
        #expect(page.items.count == 3)

        let orders = page.items[0]
        #expect(orders.identifier == "orders")
        #expect(orders.engine == "postgres")
        #expect(orders.engineVersion == "16.3")
        #expect(orders.status == "available")
        #expect(orders.adminUsername == "postgres")
        #expect(orders.databaseName == "orders")
        #expect(orders.endpoint?.address == "orders.abc123.us-east-1.rds.amazonaws.com")
        #expect(orders.endpoint?.port == 5_432)
        #expect(orders.iamAuthenticationEnabled)
        #expect(orders.isPubliclyAccessible)
        #expect(orders.clusterIdentifier == nil)

        #expect(page.items[1].clusterIdentifier == "analytics")
        #expect(page.items[1].iamAuthenticationEnabled == false)

        let creating = page.items[2]
        #expect(creating.endpoint == nil)
        #expect(creating.status == "creating")
    }

    @Test("A cluster keeps its writer and reader endpoints, and its port stays optional")
    func clusters() throws {
        let page = try #require(RDSDescribeResponseParser.parseClusters(Data(Self.clustersXML.utf8)))
        #expect(page.marker == nil)
        #expect(page.items.count == 2)

        let analytics = page.items[0]
        #expect(analytics.identifier == "analytics")
        #expect(analytics.endpoint == "analytics.cluster-abc123.us-east-1.rds.amazonaws.com")
        #expect(analytics.readerEndpoint == "analytics.cluster-ro-abc123.us-east-1.rds.amazonaws.com")
        #expect(analytics.port == nil)
        #expect(analytics.databaseName == "analytics")
        #expect(analytics.adminUsername == "admin")
        #expect(analytics.iamAuthenticationEnabled)
        #expect(analytics.members.count == 2)
        #expect(analytics.members.first?.isWriter == true)
        #expect(analytics.members.last?.isWriter == false)

        let pending = page.items[1]
        #expect(pending.endpoint == nil)
        #expect(pending.port == 5_432)
        #expect(pending.members.isEmpty)
    }

    @Test("A response that is not RDS XML is reported rather than guessed")
    func malformed() {
        #expect(RDSDescribeResponseParser.parseInstances(Data("not xml".utf8)) == nil)
        let empty = RDSDescribeResponseParser.parseInstances(
            Data("<DescribeDBInstancesResponse><DescribeDBInstancesResult/></DescribeDBInstancesResponse>".utf8)
        )
        #expect(empty?.items.isEmpty == true)
        #expect(empty?.marker == nil)
    }
}
