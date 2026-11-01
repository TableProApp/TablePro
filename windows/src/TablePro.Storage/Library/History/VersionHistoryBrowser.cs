namespace TablePro.Storage.Library.History;

public enum VersionListState
{
    Loading,
    Failed,
    Loaded,
}

public enum VersionDetailState
{
    Empty,
    Loading,
    Failed,
    Loaded,
}

public enum VersionRestoreOutcome
{
    Restored,
    Declined,
    Failed,
    NotAllowed,
}

/// <summary>Two versions side by side, the older one first, and how they differ.</summary>
public sealed record VersionHistoryComparison(VersionEntry Older, VersionEntry Newer, VersionComparison Outcome);

/// <summary>The selected version's text and its comparison with the baseline <see cref="VersionPage.BaselineFor"/> picks.</summary>
public sealed record VersionHistoryDetail(VersionEntry Entry, string Content, VersionHistoryComparison? Comparison);

/// <summary>
/// The state behind the version history view, without any UI: the list, the selected version, its text and diff,
/// and restoring. It is the macOS app's version history view model; the view only draws what this holds. Methods
/// resume on the caller's context and <see cref="Changed"/> fires there.
/// </summary>
public sealed class VersionHistoryBrowser(IVersionHistoryProvider provider)
{
    private readonly Dictionary<VersionReference, string> _pastContent = [];
    private CancellationTokenSource? _detail;
    private int _listGeneration;

    public event EventHandler? Changed;

    public VersionListState ListState { get; private set; } = VersionListState.Loading;

    public string? ListError { get; private set; }

    public VersionPage Page { get; private set; } = VersionPage.Empty;

    public VersionReference? Selection { get; private set; }

    public VersionDetailState DetailState { get; private set; } = VersionDetailState.Empty;

    public string? DetailError { get; private set; }

    public VersionHistoryDetail? Detail { get; private set; }

    public bool IsRestoring { get; private set; }

    public VersionEntry? SelectedEntry => Selection is null ? null : Page.Entries.FirstOrDefault(e => e.Reference == Selection);

    public bool CanRestoreSelection => SelectedEntry is { IsCurrent: false } && !IsRestoring;

    /// <summary>
    /// Loads the list. A refresh that fails keeps what is shown, unless the file itself is gone; a selection that
    /// still exists stays selected and is read again.
    /// </summary>
    public async Task LoadAsync(CancellationToken cancellationToken = default)
    {
        var generation = ++_listGeneration;
        if (Page.Entries.Count == 0)
        {
            ListState = VersionListState.Loading;
            Raise();
        }

        VersionPage loaded;
        try
        {
            loaded = await provider.LoadHistoryAsync(cancellationToken);
        }
        catch (Exception ex) when (ex is VersionHistoryException or IOException or UnauthorizedAccessException)
        {
            if (generation != _listGeneration)
            {
                return;
            }

            var gone = ex is VersionHistoryException { Error: VersionHistoryError.SubjectNotFound };
            if (Page.Entries.Count > 0 && !gone)
            {
                return;
            }

            Page = VersionPage.Empty;
            Selection = null;
            Detail = null;
            DetailState = VersionDetailState.Empty;
            ListState = VersionListState.Failed;
            ListError = ex.Message;
            Raise();
            return;
        }

        if (generation != _listGeneration)
        {
            return;
        }

        Page = loaded;
        ListState = VersionListState.Loaded;
        ListError = null;
        var keep = Selection is not null && loaded.Entries.Any(e => e.Reference == Selection);
        await SelectAsync(keep ? Selection : loaded.Entries.Count > 0 ? loaded.Entries[0].Reference : null, force: true);
    }

    public Task SelectAsync(VersionReference? reference) => SelectAsync(reference, force: false);

    /// <summary>
    /// Restores a past version. When the restore would replace text that exists nowhere else, <paramref name="confirm"/>
    /// is asked first and a refusal changes nothing.
    /// </summary>
    public async Task<(VersionRestoreOutcome Outcome, string? Error)> RestoreAsync(VersionEntry entry, Func<Task<bool>> confirm, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(entry);
        ArgumentNullException.ThrowIfNull(confirm);
        if (entry.IsCurrent || IsRestoring)
        {
            return (VersionRestoreOutcome.NotAllowed, null);
        }

        IsRestoring = true;
        Raise();
        try
        {
            var plan = await provider.PrepareRestoreAsync(entry.Reference, cancellationToken);
            if (plan.ReplacesUncommittedChanges && !await confirm())
            {
                return (VersionRestoreOutcome.Declined, null);
            }

            await plan.Apply(cancellationToken);
            Selection = VersionReference.Current;
            await LoadAsync(cancellationToken);
            return (VersionRestoreOutcome.Restored, null);
        }
        catch (Exception ex) when (ex is VersionHistoryException or IOException or UnauthorizedAccessException)
        {
            return (VersionRestoreOutcome.Failed, ex.Message);
        }
        finally
        {
            IsRestoring = false;
            Raise();
        }
    }

    /// <summary>A version's text. A past version is read once and kept; the current text is read every time, since it changes.</summary>
    public async Task<string> ContentAsync(VersionReference reference, CancellationToken cancellationToken = default)
    {
        if (_pastContent.TryGetValue(reference, out var cached))
        {
            return cached;
        }

        var content = await provider.ContentAsync(reference, cancellationToken);
        if (reference is not CurrentVersion)
        {
            _pastContent[reference] = content;
        }

        return content;
    }

    private async Task SelectAsync(VersionReference? reference, bool force)
    {
        if (!force && reference == Selection)
        {
            return;
        }

        if (_detail is not null)
        {
            await _detail.CancelAsync();
            _detail.Dispose();
        }

        Selection = reference;
        var entry = SelectedEntry;
        if (entry is null)
        {
            _detail = null;
            Detail = null;
            DetailState = VersionDetailState.Empty;
            Raise();
            return;
        }

        var cancellation = new CancellationTokenSource();
        _detail = cancellation;
        if (Detail?.Entry.Reference != entry.Reference)
        {
            DetailState = VersionDetailState.Loading;
            Raise();
        }

        try
        {
            var content = await ContentAsync(entry.Reference, cancellation.Token);
            var comparison = await CompareAsync(entry, content, Page.BaselineFor(entry.Reference), cancellation.Token);
            if (cancellation.IsCancellationRequested)
            {
                return;
            }

            Detail = new VersionHistoryDetail(entry, content, comparison);
            DetailState = VersionDetailState.Loaded;
            DetailError = null;
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is VersionHistoryException or IOException or UnauthorizedAccessException)
        {
            if (cancellation.IsCancellationRequested)
            {
                return;
            }

            Detail = null;
            DetailState = VersionDetailState.Failed;
            DetailError = ex.Message;
        }

        Raise();
    }

    private async Task<VersionHistoryComparison?> CompareAsync(VersionEntry entry, string content, VersionEntry? baseline, CancellationToken cancellationToken)
    {
        if (baseline is null)
        {
            return null;
        }

        var baselineContent = await ContentAsync(baseline.Reference, cancellationToken);
        var (older, newer) = entry.IsCurrent ? (baseline, entry) : (entry, baseline);
        var (olderText, newerText) = entry.IsCurrent ? (baselineContent, content) : (content, baselineContent);
        var outcome = await Task.Run(() => VersionComparison.Compare(olderText, newerText), cancellationToken);
        return new VersionHistoryComparison(older, newer, outcome);
    }

    private void Raise() => Changed?.Invoke(this, EventArgs.Empty);
}
