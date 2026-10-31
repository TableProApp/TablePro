using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// The DynamoDB calls the driver makes. <see cref="IAmazonDynamoDB"/> has well over a hundred members; this narrow
/// seam lets paging and save logic be tested against a fake.
/// </summary>
public interface IDynamoDbApi : IDisposable
{
    Task<ListTablesResponse> ListTablesAsync(ListTablesRequest request, CancellationToken cancellationToken);

    Task<DescribeTableResponse> DescribeTableAsync(DescribeTableRequest request, CancellationToken cancellationToken);

    Task<ScanResponse> ScanAsync(ScanRequest request, CancellationToken cancellationToken);

    Task<ExecuteStatementResponse> ExecuteStatementAsync(ExecuteStatementRequest request, CancellationToken cancellationToken);

    Task<TransactWriteItemsResponse> TransactWriteItemsAsync(TransactWriteItemsRequest request, CancellationToken cancellationToken);
}

internal sealed class AmazonDynamoDbApi(IAmazonDynamoDB client) : IDynamoDbApi
{
    public Task<ListTablesResponse> ListTablesAsync(ListTablesRequest request, CancellationToken cancellationToken) =>
        client.ListTablesAsync(request, cancellationToken);

    public Task<DescribeTableResponse> DescribeTableAsync(DescribeTableRequest request, CancellationToken cancellationToken) =>
        client.DescribeTableAsync(request, cancellationToken);

    public Task<ScanResponse> ScanAsync(ScanRequest request, CancellationToken cancellationToken) =>
        client.ScanAsync(request, cancellationToken);

    public Task<ExecuteStatementResponse> ExecuteStatementAsync(ExecuteStatementRequest request, CancellationToken cancellationToken) =>
        client.ExecuteStatementAsync(request, cancellationToken);

    public Task<TransactWriteItemsResponse> TransactWriteItemsAsync(TransactWriteItemsRequest request, CancellationToken cancellationToken) =>
        client.TransactWriteItemsAsync(request, cancellationToken);

    public void Dispose() => client.Dispose();
}
