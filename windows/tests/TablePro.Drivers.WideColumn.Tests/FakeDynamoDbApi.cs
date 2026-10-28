using Amazon.DynamoDBv2.Model;
using TablePro.Drivers.DynamoDb;

namespace TablePro.Drivers.WideColumn.Tests;

/// <summary>Answers each call from a handler and records every request it saw.</summary>
internal sealed class FakeDynamoDbApi : IDynamoDbApi
{
    public List<ExecuteStatementRequest> Statements { get; } = [];

    public List<ScanRequest> Scans { get; } = [];

    public List<TransactWriteItemsRequest> Transactions { get; } = [];

    public Func<ExecuteStatementRequest, ExecuteStatementResponse> OnStatement { get; set; } = _ => new ExecuteStatementResponse();

    public Func<ScanRequest, ScanResponse> OnScan { get; set; } = _ => new ScanResponse();

    public Func<DescribeTableRequest, DescribeTableResponse> OnDescribe { get; set; } = _ => new DescribeTableResponse();

    public Task<ListTablesResponse> ListTablesAsync(ListTablesRequest request, CancellationToken cancellationToken) =>
        Task.FromResult(new ListTablesResponse { TableNames = [] });

    public Task<DescribeTableResponse> DescribeTableAsync(DescribeTableRequest request, CancellationToken cancellationToken) =>
        Task.FromResult(OnDescribe(request));

    public Task<ScanResponse> ScanAsync(ScanRequest request, CancellationToken cancellationToken)
    {
        Scans.Add(request);
        return Task.FromResult(OnScan(request));
    }

    public Task<ExecuteStatementResponse> ExecuteStatementAsync(ExecuteStatementRequest request, CancellationToken cancellationToken)
    {
        Statements.Add(request);
        return Task.FromResult(OnStatement(request));
    }

    public Task<TransactWriteItemsResponse> TransactWriteItemsAsync(TransactWriteItemsRequest request, CancellationToken cancellationToken)
    {
        Transactions.Add(request);
        return Task.FromResult(new TransactWriteItemsResponse());
    }

    public void Dispose()
    {
    }

    /// <summary>A table of <paramref name="count"/> items keyed by a Number "id", scanned in id order, Limit items at a time.</summary>
    public static Func<ScanRequest, ScanResponse> NumberedTable(int count) => request =>
    {
        var start = request.ExclusiveStartKey is { } key ? int.Parse(key["id"].N, System.Globalization.CultureInfo.InvariantCulture) + 1 : 0;
        var limit = request.Limit ?? count;
        var items = Enumerable.Range(start, Math.Max(0, Math.Min(limit, count - start)))
            .Select(i => new Dictionary<string, AttributeValue>
            {
                ["id"] = new() { N = i.ToString(System.Globalization.CultureInfo.InvariantCulture) },
                ["even"] = new() { BOOL = i % 2 == 0 },
            })
            .ToList();
        var last = start + items.Count < count && items.Count > 0 ? new Dictionary<string, AttributeValue> { ["id"] = items[^1]["id"] } : null;
        return new ScanResponse { Items = items, LastEvaluatedKey = last, ScannedCount = items.Count };
    };
}
