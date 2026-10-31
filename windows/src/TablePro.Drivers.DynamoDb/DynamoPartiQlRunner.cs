using System.Diagnostics;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.Model;
using Amazon.Runtime;
using TablePro.Core.Localization;
using TablePro.Core.Results;
using TablePro.Core.Sql;
using TablePro.Drivers.DynamoDb.Localization;

namespace TablePro.Drivers.DynamoDb;

/// <summary>
/// Runs one PartiQL statement with ExecuteStatement, following NextToken until the row limit. A page can come back
/// empty with a token when a WHERE clause filtered every item DynamoDB read, so paging continues on the token alone.
/// </summary>
public static class DynamoPartiQlRunner
{
    public static async Task<StatementResult> RunAsync(IDynamoDbApi api, string statement, ExecuteOptions options, CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        var text = statement.Trim().TrimEnd(';').TrimEnd();
        var limit = Math.Max(options.RowLimit, 1);
        var items = new List<Dictionary<string, AttributeValue>>();
        var messages = new List<string>();
        double capacity = 0;
        var requests = 0;
        var truncated = false;
        string? nextToken = null;

        try
        {
            do
            {
                cancellationToken.ThrowIfCancellationRequested();
                var response = await api.ExecuteStatementAsync(
                    new ExecuteStatementRequest
                    {
                        Statement = text,
                        NextToken = nextToken,
                        ReturnConsumedCapacity = ReturnConsumedCapacity.TOTAL,
                    },
                    cancellationToken);
                requests++;
                capacity += response.ConsumedCapacity?.CapacityUnits ?? 0;

                foreach (var item in response.Items ?? [])
                {
                    if (items.Count == limit)
                    {
                        truncated = true;
                        break;
                    }

                    items.Add(item);
                }

                nextToken = string.IsNullOrEmpty(response.NextToken) ? null : response.NextToken;
                truncated |= items.Count == limit && nextToken is not null;
            }
            while (!truncated && nextToken is not null);

            messages.Add(DynamoDbStrings.Plural("DynamoDb/ConsumedCapacity", requests, capacity));
            var isRead = PartiQlDialect.Instance.Classify(text) == StatementKind.Read;
            if (!isRead && items.Count == 0)
            {
                // A PartiQL write names exactly one item by its key and fails outright when it cannot apply.
                return new StatementResult(statement, [], 1, stopwatch.Elapsed, Messages: messages);
            }

            var set = DynamoItemTable.Build(items, [], truncated);
            return new StatementResult(statement, [set], items.Count, stopwatch.Elapsed, Messages: messages);
        }
        catch (OperationCanceledException)
        {
            return new StatementResult(statement, [], -1, stopwatch.Elapsed, CoreStrings.Get("Driver/QueryCancelled"), messages);
        }
        catch (AmazonServiceException ex)
        {
            return new StatementResult(statement, [], -1, stopwatch.Elapsed, Describe(ex), messages);
        }
        catch (AmazonClientException ex)
        {
            return new StatementResult(statement, [], -1, stopwatch.Elapsed, ex.Message, messages);
        }
    }

    public static string Describe(AmazonServiceException ex) =>
        string.IsNullOrEmpty(ex.ErrorCode) ? ex.Message : $"{ex.ErrorCode}: {ex.Message}";
}
