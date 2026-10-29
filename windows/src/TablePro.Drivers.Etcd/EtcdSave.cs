using System.Globalization;
using System.Text;
using TablePro.Core.Editing;
using TablePro.Drivers.Etcd.Localization;

namespace TablePro.Drivers.Etcd;

/// <summary>
/// Turns grid edits into etcd transactions. Each change carries a comparison that proves the grid's view still holds
/// (the key exists for an update or delete, is absent for an insert), so a transaction either applies every change or none.
/// </summary>
internal static class EtcdSave
{
    // etcd refuses a transaction with more operations than --max-txn-ops, 128 by default.
    public const int MaxOperations = 128;

    private static readonly HashSet<string> Editable = new(StringComparer.OrdinalIgnoreCase) { EtcdRows.KeyColumn, EtcdRows.ValueColumn, EtcdRows.LeaseColumn };

    public static byte[] Bytes(object? value) => value switch
    {
        null => [],
        byte[] bytes => bytes,
        string text => Encoding.UTF8.GetBytes(text),
        IFormattable formattable => Encoding.UTF8.GetBytes(formattable.ToString(null, CultureInfo.InvariantCulture)),
        _ => Encoding.UTF8.GetBytes(value.ToString() ?? string.Empty),
    };

    /// <summary>The lease a row names, 0 to detach, or null when the row leaves the lease alone.</summary>
    public static long? Lease(IReadOnlyDictionary<string, object?> values)
    {
        if (!TryGet(values, EtcdRows.LeaseColumn, out var lease))
        {
            return null;
        }

        var text = lease switch
        {
            null => string.Empty,
            long l => l.ToString(CultureInfo.InvariantCulture),
            _ => Convert.ToString(lease, CultureInfo.InvariantCulture)?.Trim() ?? string.Empty,
        };
        return text.Length == 0 ? 0 : EtcdCommandParser.ParseLeaseId(text);
    }

    /// <summary>The key of each update that renames its row, whose current value and lease the transaction must copy.</summary>
    public static IEnumerable<byte[]> RenameSources(IReadOnlyList<RowChange> changes)
    {
        foreach (var change in changes)
        {
            if (change is RowUpdate update && TryGet(update.Values, EtcdRows.KeyColumn, out var newKey))
            {
                var oldKey = KeyOf(update.Key);
                if (!oldKey.AsSpan().SequenceEqual(Bytes(newKey)))
                {
                    yield return oldKey;
                }
            }
        }
    }

    /// <summary>Splits the changes into transactions of at most <see cref="MaxOperations"/> operations each.</summary>
    public static List<EtcdTxnRequest> BuildTransactions(IReadOnlyList<RowChange> changes, IReadOnlyDictionary<string, EtcdKeyValue> renameSources)
    {
        var transactions = new List<EtcdTxnRequest>();
        var current = new EtcdTxnRequest();
        foreach (var change in changes)
        {
            var (compares, operations) = Build(change, renameSources);
            if (current.Success.Count + operations.Count > MaxOperations && current.Success.Count > 0)
            {
                transactions.Add(current);
                current = new EtcdTxnRequest();
            }

            current.Compare.AddRange(compares);
            current.Success.AddRange(operations);
        }

        if (current.Success.Count > 0)
        {
            transactions.Add(current);
        }

        return transactions;
    }

    public static byte[] KeyOf(IReadOnlyDictionary<string, object?> key) =>
        TryGet(key, EtcdRows.KeyColumn, out var value) && Bytes(value) is { Length: > 0 } bytes
            ? bytes
            : throw new InvalidOperationException(EtcdStrings.Get("Etcd/ChangeHasNoKey"));

    public static string KeyName(byte[] key) => Convert.ToBase64String(key);

    private static (List<EtcdCompare> Compares, List<EtcdRequestOp> Operations) Build(RowChange change, IReadOnlyDictionary<string, EtcdKeyValue> renameSources)
    {
        switch (change)
        {
            case RowInsert insert:
            {
                Refuse(insert.Values);
                var key = KeyOf(insert.Values);
                var put = new EtcdPutRequest
                {
                    Key = key,
                    Value = TryGet(insert.Values, EtcdRows.ValueColumn, out var value) ? Bytes(value) : [],
                    Lease = Lease(insert.Values) ?? 0,
                };
                return ([Absent(key)], [new EtcdRequestOp { RequestPut = put }]);
            }

            case RowDelete delete:
            {
                var key = KeyOf(delete.Key);
                return ([Exists(key)], [new EtcdRequestOp { RequestDeleteRange = new EtcdDeleteRangeRequest { Key = key } }]);
            }

            case RowUpdate update:
            {
                Refuse(update.Values);
                var oldKey = KeyOf(update.Key);
                var newKey = TryGet(update.Values, EtcdRows.KeyColumn, out var renamed) ? Bytes(renamed) : oldKey;
                var hasValue = TryGet(update.Values, EtcdRows.ValueColumn, out var value);
                var lease = Lease(update.Values);
                if (newKey.AsSpan().SequenceEqual(oldKey))
                {
                    var put = new EtcdPutRequest
                    {
                        Key = oldKey,
                        Value = hasValue ? Bytes(value) : null,
                        IgnoreValue = !hasValue,
                        Lease = lease ?? 0,
                        IgnoreLease = lease is null,
                    };
                    return ([Exists(oldKey)], [new EtcdRequestOp { RequestPut = put }]);
                }

                if (newKey.Length == 0)
                {
                    throw new InvalidOperationException(EtcdStrings.Get("Etcd/EmptyKey"));
                }

                // A rename is a put of the new key and a delete of the old one; the old key's revision must still be the
                // one read, so a value changed by someone else in between is not copied over stale.
                var source = renameSources.TryGetValue(KeyName(oldKey), out var found)
                    ? found
                    : throw new InvalidOperationException(EtcdStrings.Format("Etcd/RenameSourceGone", EtcdRows.KeyText(oldKey)));
                var copy = new EtcdPutRequest
                {
                    Key = newKey,
                    Value = hasValue ? Bytes(value) : source.Value ?? [],
                    Lease = lease ?? source.Lease,
                };
                return (
                    [new EtcdCompare { Key = oldKey, Target = "MOD", Result = "EQUAL", ModRevision = source.ModRevision }, Absent(newKey)],
                    [new EtcdRequestOp { RequestPut = copy }, new EtcdRequestOp { RequestDeleteRange = new EtcdDeleteRangeRequest { Key = oldKey } }]);
            }

            default:
                throw new ArgumentOutOfRangeException(nameof(change));
        }
    }

    private static EtcdCompare Exists(byte[] key) => new() { Key = key, Target = "VERSION", Result = "GREATER", Version = 0 };

    private static EtcdCompare Absent(byte[] key) => new() { Key = key, Target = "VERSION", Result = "EQUAL", Version = 0 };

    private static void Refuse(IReadOnlyDictionary<string, object?> values)
    {
        foreach (var column in values.Keys)
        {
            if (!Editable.Contains(column))
            {
                throw new NotSupportedException(EtcdStrings.Format("Etcd/KeepsColumn", column));
            }
        }
    }

    private static bool TryGet(IReadOnlyDictionary<string, object?> values, string column, out object? value)
    {
        foreach (var (name, candidate) in values)
        {
            if (string.Equals(name, column, StringComparison.OrdinalIgnoreCase))
            {
                value = candidate;
                return true;
            }
        }

        value = null;
        return false;
    }
}
