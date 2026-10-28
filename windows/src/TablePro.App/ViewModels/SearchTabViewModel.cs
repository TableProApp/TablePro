using System.Collections.ObjectModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using TablePro.App.Services;
using TablePro.Core.Browse;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>One table where the searched text appears.</summary>
public sealed record SearchHit(DatabaseObject Table, int Matches, bool More, string Sample)
{
    public string Title => Table.Name.ToString();

    public string Detail => More
        ? string.Create(CultureInfo.CurrentCulture, $"{Matches:N0}+ rows")
        : string.Create(CultureInfo.CurrentCulture, $"{Matches:N0} rows");
}

/// <summary>
/// Searches every table of the current schema for a value, the way the macOS app's database search does: each table's
/// text columns with a case-insensitive contains, a few tables at a time over the session's pool.
/// </summary>
public sealed partial class SearchTabViewModel : TabViewModel
{
    private const int MatchesShown = 50;
    private const int MaxTables = 500;
    private const int Parallel = 4;

    private readonly WorkspaceContext _context;
    private CancellationTokenSource? _search;

    public SearchTabViewModel(WorkspaceContext context)
    {
        _context = context;
        Title = "Search";
        Subtitle = context.Session.CurrentSchema ?? context.Session.Profile.Name;
    }

    public override string Glyph => "";

    public ObservableCollection<SearchHit> Hits { get; } = [];

    [ObservableProperty]
    public partial string Query { get; set; } = string.Empty;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(StopCommand))]
    public partial bool IsSearching { get; set; }

    [ObservableProperty]
    public partial double Progress { get; set; }

    [RelayCommand]
    public async Task SearchAsync()
    {
        var text = Query.Trim();
        if (text.Length == 0)
        {
            return;
        }

        _search?.Cancel();
        _search = new CancellationTokenSource();
        var token = _search.Token;
        Hits.Clear();
        IsSearching = true;
        IsBusy = true;
        var tables = _context.Session.Objects.Where(o => o.Kind is ObjectKind.Table or ObjectKind.View).Take(MaxTables).ToArray();
        var done = 0;
        try
        {
            using var gate = new SemaphoreSlim(Parallel);
            var work = tables.Select(async table =>
            {
                await gate.WaitAsync(token);
                try
                {
                    var hit = await SearchTableAsync(table, text, token);
                    if (hit is not null)
                    {
                        Hits.Add(hit);
                    }
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    // A table the login cannot read, or whose columns cannot be cast to text, is skipped.
                }
                finally
                {
                    gate.Release();
                    done++;
                    Progress = done * 100.0 / tables.Length;
                    StatusText = string.Create(CultureInfo.CurrentCulture, $"Searched {done:N0} of {tables.Length:N0} tables · {Hits.Count:N0} with matches");
                }
            });
            await Task.WhenAll(work);
        }
        catch (OperationCanceledException)
        {
            StatusText = "Search stopped.";
        }
        finally
        {
            IsSearching = false;
            IsBusy = false;
        }
    }

    [RelayCommand(CanExecute = nameof(IsSearching))]
    private void Stop() => _search?.Cancel();

    /// <summary>The filter that shows the searched text in a table tab.</summary>
    public FilterRule FilterFor() => new(null, FilterOperator.Contains, Query.Trim());

    public override ValueTask DisposeAsync()
    {
        _search?.Cancel();
        _search?.Dispose();
        return base.DisposeAsync();
    }

    private async Task<SearchHit?> SearchTableAsync(DatabaseObject table, string text, CancellationToken token)
    {
        var structure = await _context.Session.GetStructureAsync(table.Name, token);
        var columns = structure.Columns.Where(c => IsTextual(c.DataType)).Select(c => c.Name).ToArray();
        if (columns.Length == 0)
        {
            return null;
        }

        var filter = new BrowseFilter([new FilterRule(null, FilterOperator.Contains, text)]) { SearchColumns = columns };
        var page = await _context.Session.Database.BrowseAsync(new BrowseRequest(table.Name, filter, [], 0, MatchesShown + 1), token);
        if (page.RowCount == 0)
        {
            return null;
        }

        var sample = page.Rows[0].Select(Core.Results.CellFormatter.FormatForCell).FirstOrDefault(v => v.Contains(text, StringComparison.OrdinalIgnoreCase)) ?? string.Empty;
        return new SearchHit(table, Math.Min(page.RowCount, MatchesShown), page.RowCount > MatchesShown, sample);
    }

    private static bool IsTextual(string type)
    {
        var t = type.ToLowerInvariant();
        return t.Contains("char", StringComparison.Ordinal) || t.Contains("text", StringComparison.Ordinal) || t.Contains("string", StringComparison.Ordinal)
            || t.Contains("json", StringComparison.Ordinal) || t.Contains("uuid", StringComparison.Ordinal) || t.Contains("clob", StringComparison.Ordinal)
            || t.Contains("xml", StringComparison.Ordinal) || t.Contains("enum", StringComparison.Ordinal) || t.Contains("citext", StringComparison.Ordinal);
    }
}
