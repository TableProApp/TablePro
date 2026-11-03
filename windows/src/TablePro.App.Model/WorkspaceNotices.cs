using TablePro.Interop;

namespace TablePro.App.Model;

public sealed record HeldTab(string Title, TransactionState Transaction, bool Selected);

// The shown tab has its own bar above its results, so this one names another tab holding a transaction.
public sealed record TransactionElsewhere(int Target, string Title, TransactionState Transaction, int Count);

public enum HealthNoticeKind
{
    Reconnecting,
    Offline,
    Failed,
}

public sealed record HealthNotice(HealthNoticeKind Kind, int Attempt, CoreError? Reason)
{
    public bool OffersReconnect => Kind is HealthNoticeKind.Offline or HealthNoticeKind.Failed;
}

public static class WorkspaceNotices
{
    public static bool Holds(TransactionState state) => state is TransactionState.InTransaction or TransactionState.Failed;

    // tabs is in tab strip order; the bar points at the first held tab that is not shown.
    public static TransactionElsewhere? Elsewhere(IReadOnlyList<HeldTab> tabs)
    {
        ArgumentNullException.ThrowIfNull(tabs);
        var others = tabs
            .Select((tab, index) => (tab, index))
            .Where(item => !item.tab.Selected && Holds(item.tab.Transaction))
            .ToList();
        if (others.Count == 0)
        {
            return null;
        }

        var (first, target) = others[0];
        return new TransactionElsewhere(target, first.Title, first.Transaction, others.Count);
    }

    public static HealthNotice? For(SessionHealth health) => health switch
    {
        SessionHealth.Reconnecting reconnecting => new HealthNotice(HealthNoticeKind.Reconnecting, reconnecting.Attempt, null),
        SessionHealth.Offline => new HealthNotice(HealthNoticeKind.Offline, 0, null),
        SessionHealth.Failed failed => new HealthNotice(HealthNoticeKind.Failed, 0, failed.Reason),
        _ => null,
    };

    // A key-value engine queues commands and runs them with EXEC, as the Linux app sends them.
    public static string EndTransaction(DataModel model, bool commit) => (model, commit) switch
    {
        (DataModel.KeyValue, true) => "EXEC",
        (DataModel.KeyValue, false) => "DISCARD",
        (_, true) => "COMMIT",
        _ => "ROLLBACK",
    };
}
