using System.Text;
using TablePro.App.Services;
using TablePro.Core.Generation;
using TablePro.Core.Results;
using TablePro.Core.Schema;

namespace TablePro.App.ViewModels;

/// <summary>
/// The state of the Generate Rows sheet: the table as the generator reads it, each column's generator, the row count
/// and seed, the problems that stop a run, and a preview of the first rows the run would insert.
/// </summary>
public sealed class RowGeneratorViewModel(WorkspaceContext context, DatabaseObject table)
{
    public const int PreviewRowCount = 10;

    /// <summary>Open as SQL writes one INSERT per row, so it stops where an editor tab stays usable.</summary>
    public const int ScriptRowLimit = 10_000;

    public DatabaseObject Table { get; } = table;

    public RowGenerationTarget? Target { get; private set; }

    public RowGenerationSettings Settings { get; private set; } = new(RowGenerationSettings.DefaultRowCount, RowGenerationSettings.RandomSeed(), new Dictionary<string, RowGeneratorSettings>());

    public IReadOnlyList<RowGenerationColumn> Columns => Target?.Model.Columns ?? [];

    public event EventHandler? SettingsChanged;

    public async Task LoadAsync(CancellationToken cancellationToken)
    {
        var target = await RowGenerationLoader.LoadAsync(context.Session.Database, Table.Name, cancellationToken);
        Target = target;
        Settings = RowGenerationDefaults.ForTable(target.Model, DateOnly.FromDateTime(DateTime.Now), Settings.Seed, Settings.RowCount);
    }

    public RowGeneratorSettings SettingsFor(string column) => Settings.Columns[column];

    public void Update(string column, Func<RowGeneratorSettings, RowGeneratorSettings> change)
    {
        ArgumentNullException.ThrowIfNull(change);
        Settings = Settings.With(column, change(Settings.Columns[column]));
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Switching generator keeps the ranges already set, so going back and forth loses nothing.</summary>
    public void SetKind(string column, RowGeneratorKind kind) => Update(column, s => s with { Kind = kind });

    public void SetRowCount(int rows)
    {
        Settings = Settings with { RowCount = rows };
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void SetSeed(ulong seed)
    {
        Settings = Settings with { Seed = seed };
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    public void ShuffleSeed() => SetSeed(RowGenerationSettings.RandomSeed());

    public IReadOnlyList<RowGenerationIssue> Issues => Target is null ? [] : RowGenerationValidation.Issues(Settings, Target.Model);

    public bool CanGenerate => Target is not null && Issues.Count == 0;

    public bool CanOpenScript => CanGenerate && Settings.RowCount <= ScriptRowLimit;

    public RowGenerationEngine CreateEngine() =>
        Target is { } target ? new RowGenerationEngine(target.Model, Settings, target.NullsAreDistinct) : throw new InvalidOperationException("The table is not loaded.");

    /// <summary>The first rows the run would insert, or why there are none.</summary>
    public (ResultSet? Rows, string? Problem) Preview()
    {
        if (Target is null || Issues.Count > 0)
        {
            return (null, null);
        }

        try
        {
            var engine = CreateEngine();
            var rows = engine.NextRows(Math.Min(PreviewRowCount, Settings.RowCount));
            var columns = engine.ColumnNames.Select(n => new ResultColumn(n, Columns.First(c => c.Name == n).TypeName, typeof(object))).ToArray();
            return (new ResultSet(columns, rows), null);
        }
        catch (RowGenerationException ex)
        {
            return (null, ex.Message);
        }
    }

    public Task<int> InsertAsync(IProgress<int> progress, CancellationToken cancellationToken) =>
        RowGenerationWriter.InsertAsync(context.Session.Database, Target!, CreateEngine(), Settings.RowCount, progress, cancellationToken);

    /// <summary>The rows as INSERT statements with literal values, for the user to read and run in an editor.</summary>
    public string InsertScript()
    {
        var dialect = context.Session.Dialect;
        var engine = CreateEngine();
        var target = dialect.Qualify(Table.Name);
        var columns = string.Join(", ", engine.ColumnNames.Select(dialect.QuoteIdentifier));
        var script = new StringBuilder();
        for (var i = 0; i < Settings.RowCount; i++)
        {
            var row = engine.NextRow();
            script.Append("INSERT INTO ").Append(target).Append(" (").Append(columns).Append(") VALUES (")
                .AppendJoin(", ", row.Select(dialect.Literal)).Append(");\n");
        }

        return script.ToString();
    }
}
