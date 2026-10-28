using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Export;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Core.Sql;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Helpers;

/// <summary>The copy and export actions every grid offers, in its context menu and its toolbar.</summary>
internal static class GridCommands
{
    public static void AddCopyItems(MenuFlyout menu, DataGridView grid, SqlDialect dialect, ObjectName? table)
    {
        menu.Items.Add(Item("Copy", "", () => grid.CopySelection(), "Ctrl+C"));
        menu.Items.Add(Item("Copy with Headers", "", () => grid.CopySelection(includeHeaders: true), "Ctrl+Shift+C"));
        var copyAs = new MenuFlyoutSubItem { Text = "Copy As", Icon = new FontIcon { Glyph = "" } };
        copyAs.Items.Add(Item("CSV", null, () => CopyAs(grid, ExportFormat.Csv, dialect, table)));
        copyAs.Items.Add(Item("JSON", null, () => CopyAs(grid, ExportFormat.Json, dialect, table)));
        copyAs.Items.Add(Item("SQL INSERT", null, () => CopyAs(grid, ExportFormat.SqlInsert, dialect, table)));
        copyAs.Items.Add(Item("Markdown", null, () => CopyAs(grid, ExportFormat.Markdown, dialect, table)));
        copyAs.Items.Add(Item("WHERE clause", null, () => SetClipboard(WhereClause(grid, dialect))));
        copyAs.Items.Add(Item("IN list", null, () => SetClipboard(InList(grid, dialect))));
        menu.Items.Add(copyAs);
        if (grid.ActiveCell is { } cell && grid.Source is { } source)
        {
            menu.Items.Add(Item("Copy Column Name", "", () => SetClipboard(source.Columns[cell.Column].Name)));
        }
    }

    public static MenuFlyoutItem Item(string text, string? glyph, Action action, string? accelerator = null)
    {
        var item = new MenuFlyoutItem { Text = text };
        if (glyph is not null)
        {
            item.Icon = new FontIcon { Glyph = glyph };
        }

        if (accelerator is not null)
        {
            item.KeyboardAcceleratorTextOverride = accelerator;
        }

        item.Click += (_, _) => action();
        return item;
    }

    public static void SetClipboard(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    /// <summary>Exports a whole result to a file the user picks, streaming rows to disk.</summary>
    public static async Task ExportAsync(DialogService dialogs, ResultSet result, SqlDialect dialect, ObjectName? table, string baseName)
    {
        var formats = new (string Name, ExportFormat Format)[]
        {
            ("CSV", ExportFormat.Csv), ("TSV", ExportFormat.Tsv), ("JSON", ExportFormat.Json), ("SQL INSERT", ExportFormat.SqlInsert), ("Markdown", ExportFormat.Markdown), ("Excel workbook", ExportFormat.Xlsx),
        };
        var picker = new ComboBox { Header = "Format", ItemsSource = formats.Select(f => f.Name).ToList(), SelectedIndex = 0, MinWidth = 240 };
        var header = new CheckBox { Content = "Include column names", IsChecked = true };
        var panel = new StackPanel { Spacing = 12 };
        panel.Children.Add(picker);
        panel.Children.Add(header);
        panel.Children.Add(new TextBlock { Text = $"{result.RowCount:N0} rows, {result.Columns.Count} columns", Style = (Microsoft.UI.Xaml.Style)Microsoft.UI.Xaml.Application.Current.Resources["CaptionTextBlockStyle"] });
        if (await dialogs.ShowAsync(dialogs.Create("Export", panel, "Export…", "Cancel")) != ContentDialogResult.Primary)
        {
            return;
        }

        var format = formats[Math.Max(0, picker.SelectedIndex)].Format;
        var extension = ResultExporter.FileExtension(format);
        var file = await dialogs.PickSaveFileAsync(baseName, formats[Math.Max(0, picker.SelectedIndex)].Name, extension);
        if (file is null)
        {
            return;
        }

        await using var stream = await file.OpenStreamForWriteAsync();
        stream.SetLength(0);
        await ResultExporter.WriteAsync(result, null, stream, new ExportOptions(format, header.IsChecked == true, TargetTable: table, Dialect: dialect), CancellationToken.None);
    }

    private static void CopyAs(DataGridView grid, ExportFormat format, SqlDialect dialect, ObjectName? table)
    {
        if (grid.Source is null)
        {
            return;
        }

        var snapshot = Snapshot(grid);
        SetClipboard(ResultExporter.ToText(snapshot, null, new ExportOptions(format, TargetTable: table, Dialect: dialect)));
    }

    /// <summary>The selected rectangle as its own result, so exporters see only what is selected.</summary>
    private static ResultSet Snapshot(DataGridView grid)
    {
        var source = grid.Source!;
        var (firstRow, lastRow, firstColumn, lastColumn) = grid.SelectionBounds;
        var columns = source.Columns.Skip(firstColumn).Take(lastColumn - firstColumn + 1).ToArray();
        var rows = new List<object?[]>(Math.Max(0, lastRow - firstRow + 1));
        for (var r = firstRow; r <= lastRow; r++)
        {
            var row = new object?[columns.Length];
            for (var c = 0; c < columns.Length; c++)
            {
                row[c] = source.GetValue(r, firstColumn + c);
            }

            rows.Add(row);
        }

        return new ResultSet(columns, rows);
    }

    private static string WhereClause(DataGridView grid, SqlDialect dialect)
    {
        var snapshot = Snapshot(grid);
        var rows = snapshot.Rows.Select(row => "(" + string.Join(" AND ", snapshot.Columns.Select((c, i) =>
            row[i] is null ? $"{dialect.QuoteIdentifier(c.Name)} IS NULL" : $"{dialect.QuoteIdentifier(c.Name)} = {dialect.Literal(row[i])}")) + ")");
        return string.Join("\nOR ", rows);
    }

    private static string InList(DataGridView grid, SqlDialect dialect)
    {
        var snapshot = Snapshot(grid);
        return "(" + string.Join(", ", snapshot.Rows.SelectMany(r => r).Select(dialect.Literal).Distinct()) + ")";
    }
}
