using CommunityToolkit.Mvvm.ComponentModel;
using TablePro.App.Services;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>The entity-relationship diagram of the current schema: every table with its columns and foreign keys.</summary>
public sealed partial class DiagramTabViewModel : TabViewModel
{
    /// <summary>Beyond this many tables a diagram stops being readable and costs a structure query per table.</summary>
    public const int MaxTables = 150;

    private readonly WorkspaceContext _context;

    public DiagramTabViewModel(WorkspaceContext context)
    {
        _context = context;
        Title = "Diagram";
        Subtitle = context.Session.CurrentSchema ?? context.Session.Profile.Name;
    }

    public override string Glyph => "";

    [ObservableProperty]
    public partial IReadOnlyList<(DatabaseObject Table, TableStructure Structure)> Tables { get; set; } = [];

    public async Task LoadAsync()
    {
        IsBusy = true;
        StatusText = "Reading structure…";
        try
        {
            var tables = _context.Session.Objects.Where(o => o.Kind == ObjectKind.Table).Take(MaxTables).ToArray();
            var loaded = new List<(DatabaseObject, TableStructure)>(tables.Length);
            foreach (var table in tables)
            {
                loaded.Add((table, await _context.Session.GetStructureAsync(table.Name, CancellationToken.None)));
                StatusText = $"Reading structure… {loaded.Count}/{tables.Length}";
            }

            Tables = loaded;
            var total = _context.Session.Objects.Count(o => o.Kind == ObjectKind.Table);
            StatusText = total > MaxTables ? $"Showing {MaxTables} of {total} tables" : $"{total} tables";
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            StatusText = ex.Message;
        }
        finally
        {
            IsBusy = false;
        }
    }
}
