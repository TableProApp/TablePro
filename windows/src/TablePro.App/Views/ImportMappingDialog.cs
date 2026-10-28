using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Import;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using ColumnDefinition = TablePro.Core.Schema.ColumnDefinition;
using GridColumn = Microsoft.UI.Xaml.Controls.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>What the mapping dialog decided: where the rows go, how the file is read and how each record becomes a row.</summary>
internal sealed record ImportPlan(
    ImportDestination Destination,
    ObjectName Table,
    CsvImportOptions CsvOptions,
    ImportRowBuilder Builder,
    IReadOnlyList<ColumnDefinition> NewTableColumns);

/// <summary>
/// The import sheet of the macOS app: the destination, how a delimited file is read, each field of the file against a
/// column (or, for a new table, the column it becomes) and the first rows as read. Changing a reading option reads
/// the file again and keeps every choice made for the fields still there.
/// </summary>
internal sealed class ImportMappingDialog
{
    private static readonly (string Name, char? Value)[] Delimiters = [("Detect", null), ("Comma", ','), ("Semicolon", ';'), ("Tab", '\t'), ("Pipe", '|')];

    private readonly Func<CsvImportOptions, Task<ImportPreview>> _readPreview;
    private readonly ImportFileFormat _format;
    private readonly ObjectName _existingTable;
    private readonly Func<ImportFieldType, string> _proposeType;
    private readonly IReadOnlyList<string> _commonTypes;
    private readonly NewTableDraft _draft = new();
    private readonly ImportMapping _mapping;

    private readonly RadioButtons _destination = new() { Header = "Import into", MaxColumns = 2 };
    private readonly TextBox _newTableName = new() { PlaceholderText = "table_name", MinWidth = 220, IsEnabled = false };
    private readonly ComboBox _delimiter = new() { Header = "Delimiter", MinWidth = 140 };
    private readonly CheckBox _hasHeader = new() { Content = "First row is a header", IsChecked = true };
    private readonly CheckBox _trim = new() { Content = "Trim spaces" };
    private readonly TextBox _nullText = new() { Header = "Null text", PlaceholderText = "NULL", Width = 110 };
    private readonly CheckBox _includeAll = new() { Content = "Import all fields", IsThreeState = false };
    private readonly StackPanel _rows = new() { Spacing = 4 };
    private readonly DataGridView _previewGrid = new() { Height = 170 };
    private readonly TextBlock _previewNote = new() { Opacity = 0.7 };
    private readonly InfoBar _problem = new() { Severity = InfoBarSeverity.Warning, IsClosable = false };
    private readonly DropDownButton _match = new() { Content = "Match Columns" };
    private ImportPreview _preview;
    private CsvImportOptions? _lastOptions;
    private ContentDialog? _dialog;
    private bool _building;

    private ImportMappingDialog(
        ImportPreview preview, ImportFileFormat format, CsvImportOptions csvOptions, Func<CsvImportOptions, Task<ImportPreview>> readPreview,
        ObjectName existingTable, IReadOnlyList<ImportTargetColumn> columns, bool canCreateTable, string proposedTableName,
        Func<ImportFieldType, string> proposeType, IReadOnlyList<string> commonTypes)
    {
        _preview = preview;
        _format = format;
        _readPreview = readPreview;
        _existingTable = existingTable;
        _proposeType = proposeType;
        _commonTypes = commonTypes;
        _mapping = new ImportMapping(preview.Fields, columns);
        _draft.Load(preview.Fields, proposeType);

        _destination.Items.Add($"Existing table {existingTable.Name}");
        _destination.Items.Add("New table");
        _destination.SelectedIndex = 0;
        _destination.Visibility = canCreateTable ? Visibility.Visible : Visibility.Collapsed;
        _newTableName.Text = proposedTableName;
        AutomationProperties.SetName(_newTableName, "New table name");
        _destination.SelectionChanged += (_, _) =>
        {
            _newTableName.IsEnabled = IsNewTable;
            BuildRows();
        };
        _newTableName.TextChanged += (_, _) => Validate();

        foreach (var (name, _) in Delimiters)
        {
            _delimiter.Items.Add(name);
        }

        _delimiter.SelectedIndex = Math.Max(0, Array.FindIndex(Delimiters, d => d.Value == csvOptions.Delimiter));
        _hasHeader.IsChecked = csvOptions.HasHeaderRow;
        _trim.IsChecked = csvOptions.TrimWhitespace;
        _nullText.Text = csvOptions.NullText;
        _lastOptions = CsvOptions;
        _delimiter.SelectionChanged += async (_, _) => await RereadAsync();
        _hasHeader.Click += async (_, _) => await RereadAsync();
        _trim.Click += async (_, _) => await RereadAsync();
        _nullText.LostFocus += async (_, _) => await RereadAsync();

        _includeAll.Click += (_, _) =>
        {
            var include = _includeAll.IsChecked == true;
            if (IsNewTable)
            {
                _draft.SetAllIncluded(include);
            }
            else
            {
                _mapping.SetAllIncluded(include);
            }

            BuildRows();
        };

        // One-shot commands rather than a mode, which would stop describing the mapping after one manual edit.
        var matchMenu = new MenuFlyout();
        var byName = new MenuFlyoutItem { Text = "Match by Name" };
        byName.Click += (_, _) =>
        {
            _mapping.MatchByName();
            BuildRows();
        };
        var byPosition = new MenuFlyoutItem { Text = "Match by Position" };
        byPosition.Click += (_, _) =>
        {
            _mapping.MatchByPosition();
            BuildRows();
        };
        matchMenu.Items.Add(byName);
        matchMenu.Items.Add(byPosition);
        _match.Flyout = matchMenu;
    }

    private bool IsNewTable => _destination.SelectedIndex == 1;

    private CsvImportOptions CsvOptions => new(
        Delimiters[Math.Max(0, _delimiter.SelectedIndex)].Value,
        _hasHeader.IsChecked == true,
        _trim.IsChecked == true,
        EmptyAsNull: true,
        NullText: _nullText.Text);

    /// <summary>Shows the dialog over the preview already read; null when the user cancels.</summary>
    public static async Task<ImportPlan?> ShowAsync(
        DialogService dialogs, string fileName, ImportPreview preview, ImportFileFormat format, CsvImportOptions csvOptions,
        Func<CsvImportOptions, Task<ImportPreview>> readPreview, ObjectName existingTable, IReadOnlyList<ImportTargetColumn> columns,
        bool canCreateTable, Func<ImportFieldType, string> proposeType, IReadOnlyList<string> commonTypes)
    {
        var proposed = Path.GetFileNameWithoutExtension(fileName.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? fileName[..^3] : fileName);
        var view = new ImportMappingDialog(preview, format, csvOptions, readPreview, existingTable, columns, canCreateTable, proposed, proposeType, commonTypes);
        var dialog = dialogs.Create($"Import {fileName}", view.BuildContent(), "Import", "Cancel");

        // The field list, the new table's settings and the preview need more room than a ContentDialog's default 548 pixels.
        dialog.Resources["ContentDialogMaxWidth"] = 1040.0;
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        view._dialog = dialog;
        view.BuildRows();
        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary || view.CurrentProblem() is not null)
        {
            return null;
        }

        return view.IsNewTable
            ? new ImportPlan(ImportDestination.NewTable, new ObjectName(existingTable.Schema, view._newTableName.Text.Trim()), view.CsvOptions, view._draft.CreateRowBuilder(), view._draft.Definition())
            : new ImportPlan(ImportDestination.ExistingTable, existingTable, view.CsvOptions, view._mapping.CreateRowBuilder(), []);
    }

    private StackPanel BuildContent()
    {
        var root = new StackPanel { Spacing = 12, MinWidth = 860 };
        var destination = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        destination.Children.Add(_destination);
        _newTableName.VerticalAlignment = VerticalAlignment.Bottom;
        destination.Children.Add(_newTableName);
        if (_destination.Visibility == Visibility.Visible)
        {
            root.Children.Add(destination);
        }

        if (_format == ImportFileFormat.Csv)
        {
            var options = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
            options.Children.Add(_delimiter);
            _hasHeader.VerticalAlignment = _trim.VerticalAlignment = VerticalAlignment.Bottom;
            options.Children.Add(_hasHeader);
            options.Children.Add(_trim);
            options.Children.Add(_nullText);
            ToolTipService.SetToolTip(_nullText, "A value that imports as null, such as NULL or \\N. Empty fields always import as null.");
            root.Children.Add(options);
        }

        var toolbar = new Grid();
        toolbar.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        toolbar.Children.Add(_includeAll);
        Grid.SetColumn(_match, 1);
        toolbar.Children.Add(_match);
        root.Children.Add(toolbar);
        root.Children.Add(new ScrollViewer { Content = _rows, MaxHeight = 260, Padding = new Thickness(0, 0, 12, 0) });

        var previewHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        previewHeader.Children.Add(new TextBlock { Text = "First rows", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        previewHeader.Children.Add(_previewNote);
        root.Children.Add(previewHeader);
        root.Children.Add(_previewGrid);
        root.Children.Add(_problem);
        return root;
    }

    private async Task RereadAsync()
    {
        // Leaving the null text box unchanged must not read the file again.
        var options = CsvOptions;
        if (_building || options == _lastOptions)
        {
            return;
        }

        _lastOptions = options;
        try
        {
            _preview = await _readPreview(options);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or UnauthorizedAccessException)
        {
            _problem.Title = "Cannot read this file";
            _problem.Message = ex.Message;
            _problem.IsOpen = true;
            return;
        }

        _mapping.Reload(_preview.Fields);
        _draft.Load(_preview.Fields, _proposeType);
        BuildRows();
    }

    /// <summary>Rebuilds the field rows and the preview from the model, which holds every choice.</summary>
    private void BuildRows()
    {
        _building = true;
        try
        {
            _rows.Children.Clear();
            _match.Visibility = IsNewTable ? Visibility.Collapsed : Visibility.Visible;
            _includeAll.Content = IsNewTable ? "Create all columns" : "Import all fields";
            _rows.Children.Add(HeaderRow());
            for (var i = 0; i < _preview.Fields.Count; i++)
            {
                _rows.Children.Add(IsNewTable ? NewTableRow(i) : MappingRow(i));
            }

            _includeAll.IsChecked = IsNewTable ? _draft.IncludesEveryColumn : _mapping.Choices.Count > 0 && _mapping.Choices.All(c => c.Include);
            BuildPreview();
        }
        finally
        {
            _building = false;
        }

        Validate();
    }

    private Grid RowGrid(params double[] widths)
    {
        var grid = new Grid { ColumnSpacing = 8 };
        foreach (var width in widths)
        {
            grid.ColumnDefinitions.Add(new GridColumn { Width = width > 0 ? new GridLength(width) : new GridLength(1, GridUnitType.Star) });
        }

        return grid;
    }

    private Grid HeaderRow()
    {
        string[] labels = IsNewTable ? ["", "Field", "Column", "Type", "Key", "Null", "Default"] : ["", "Field", "Column", "Type"];
        var grid = IsNewTable ? RowGrid(32, 0, 170, 170, 48, 48, 140) : RowGrid(32, 0, 240, 160);
        for (var i = 0; i < labels.Length; i++)
        {
            var label = new TextBlock { Text = labels[i], Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Opacity = 0.7 };
            Grid.SetColumn(label, i);
            grid.Children.Add(label);
        }

        return grid;
    }

    private static StackPanel FieldCell(ImportField field)
    {
        var cell = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        cell.Children.Add(new TextBlock { Text = field.Name, TextTrimming = TextTrimming.CharacterEllipsis });
        if (!string.IsNullOrEmpty(field.SampleValue))
        {
            cell.Children.Add(new TextBlock { Text = field.SampleValue, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1 });
        }

        return cell;
    }

    private Grid MappingRow(int index)
    {
        var field = _preview.Fields[index];
        var choice = _mapping[index];
        var grid = RowGrid(32, 0, 240, 160);
        var include = new CheckBox { IsChecked = choice.Include, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(include, $"Import {field.Name}");
        var target = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(target, $"Column for {field.Name}");
        target.Items.Add("Skip");
        foreach (var column in _mapping.ColumnNames)
        {
            target.Items.Add(column);
        }

        target.SelectedIndex = choice.Column is null ? 0 : _mapping.ColumnNames.ToList().FindIndex(c => string.Equals(c, choice.Column, StringComparison.Ordinal)) + 1;
        var type = new TextBlock { Text = _mapping.ColumnFor(choice.MappedColumn)?.DataType ?? string.Empty, VerticalAlignment = VerticalAlignment.Center, Opacity = 0.7, TextTrimming = TextTrimming.CharacterEllipsis };

        include.Click += (_, _) =>
        {
            _mapping[index] = _mapping[index] with { Include = include.IsChecked == true };
            type.Text = _mapping.ColumnFor(_mapping[index].MappedColumn)?.DataType ?? string.Empty;
            SyncIncludeAll();
            Validate();
        };
        target.SelectionChanged += (_, _) =>
        {
            if (_building)
            {
                return;
            }

            var column = target.SelectedIndex <= 0 ? null : _mapping.ColumnNames[target.SelectedIndex - 1];

            // Picking a column ticks the field and picking Skip unticks it, so the two controls never disagree.
            _mapping[index] = new ImportFieldChoice(column is not null, column);
            include.IsChecked = column is not null;
            type.Text = _mapping.ColumnFor(column)?.DataType ?? string.Empty;
            SyncIncludeAll();
            Validate();
        };

        Place(grid, include, 0);
        Place(grid, FieldCell(field), 1);
        Place(grid, target, 2);
        Place(grid, type, 3);
        return grid;
    }

    private Grid NewTableRow(int index)
    {
        var column = _draft.Columns[index];
        var settings = column.Settings;
        var grid = RowGrid(32, 0, 170, 170, 48, 48, 140);
        var include = new CheckBox { IsChecked = settings.Include, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(include, $"Create {column.Field.Name}");
        var name = new TextBox { Text = settings.Name };
        AutomationProperties.SetName(name, $"Column name for {column.Field.Name}");
        var type = new ComboBox { IsEditable = true, HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = TypeChoices(settings.Type), Text = settings.Type };
        AutomationProperties.SetName(type, $"Type of {column.Field.Name}");
        var key = new CheckBox { IsChecked = settings.IsPrimaryKey, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(key, $"{column.Field.Name} is a primary key");
        var nullable = new CheckBox { IsChecked = settings.IsNullable, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(nullable, $"{column.Field.Name} accepts null");
        var defaultValue = new TextBox { Text = settings.DefaultValue, PlaceholderText = "Default SQL" };
        AutomationProperties.SetName(defaultValue, $"Default SQL for {column.Field.Name}");
        ToolTipService.SetToolTip(defaultValue, "The SQL after DEFAULT. A text value needs its own quotes.");

        include.Click += (_, _) =>
        {
            column.Settings = column.Settings with { Include = include.IsChecked == true };
            SyncIncludeAll();
            Validate();
        };
        name.TextChanged += (_, _) =>
        {
            column.Settings = column.Settings with { Name = name.Text };
            Validate();
        };
        type.TextSubmitted += (_, e) =>
        {
            column.Settings = column.Settings with { Type = e.Text };
            Validate();
        };
        type.SelectionChanged += (_, _) =>
        {
            if (!_building && type.SelectedItem is string chosen)
            {
                column.Settings = column.Settings with { Type = chosen };
                Validate();
            }
        };
        key.Click += (_, _) =>
        {
            column.Settings = column.Settings with { IsPrimaryKey = key.IsChecked == true };
            Validate();
        };
        nullable.Click += (_, _) => column.Settings = column.Settings with { IsNullable = nullable.IsChecked == true };
        defaultValue.TextChanged += (_, _) => column.Settings = column.Settings with { DefaultValue = defaultValue.Text };

        Place(grid, include, 0);
        Place(grid, FieldCell(column.Field), 1);
        Place(grid, name, 2);
        Place(grid, type, 3);
        Place(grid, key, 4);
        Place(grid, nullable, 5);
        Place(grid, defaultValue, 6);
        return grid;
    }

    /// <summary>The engine's common types with the proposed one first, so the menu always holds what is shown.</summary>
    private List<string> TypeChoices(string current)
    {
        var choices = new List<string> { current };
        choices.AddRange(_commonTypes.Where(t => !string.Equals(t, current, StringComparison.OrdinalIgnoreCase)));
        return choices;
    }

    private static void Place(Grid grid, FrameworkElement element, int column)
    {
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    private void SyncIncludeAll() =>
        _includeAll.IsChecked = IsNewTable ? _draft.IncludesEveryColumn : _mapping.Choices.All(c => c.Include);

    private void BuildPreview()
    {
        var columns = _preview.Fields.Select(f => new ResultColumn(f.Name, f.InferredType.ToString(), typeof(object))).ToArray();
        _previewGrid.Source = new ResultGridSource(new ResultSet(columns, [.. _preview.Rows]));
        _previewNote.Text = string.Create(CultureInfo.CurrentCulture, $"{_preview.Rows.Count:N0} shown; types from the first {_preview.SampledRows:N0} rows");
    }

    private string? CurrentProblem()
    {
        if (_preview.Fields.Count == 0)
        {
            return "The file has no fields to import.";
        }

        if (!IsNewTable)
        {
            return _mapping.Problem;
        }

        return string.IsNullOrWhiteSpace(_newTableName.Text) ? "Enter a name for the new table." : _draft.Problem;
    }

    private void Validate()
    {
        var problem = CurrentProblem();
        _problem.Title = problem is null ? string.Empty : "Cannot import yet";
        _problem.Message = problem ?? string.Empty;
        _problem.IsOpen = problem is not null;
        if (_dialog is not null)
        {
            _dialog.IsPrimaryButtonEnabled = problem is null;
        }
    }
}
