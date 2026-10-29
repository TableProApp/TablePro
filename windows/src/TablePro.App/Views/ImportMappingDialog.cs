using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Import;
using TablePro.Core.Results;
using TablePro.Core.Schema;
using TablePro.Storage;
using TablePro.Storage.Import;
using ColumnDefinition = TablePro.Core.Schema.ColumnDefinition;
using GridColumn = Microsoft.UI.Xaml.Controls.ColumnDefinition;

namespace TablePro.App.Views;

/// <summary>
/// What the mapping dialog decided: where the rows go, how the file is read, how each record becomes a row and how
/// rows whose key is already in the table are treated.
/// </summary>
internal sealed record ImportPlan(
    ImportDestination Destination,
    ObjectName Table,
    CsvImportOptions CsvOptions,
    ImportRowBuilder Builder,
    IReadOnlyList<ColumnDefinition> NewTableColumns,
    ImportRowWriting Writing);

/// <summary>
/// What the dialog offers for the rows already in the table: its keys, whether the session can match at all, and
/// whether it can empty the table and import in one transaction.
/// </summary>
internal sealed record ImportMatchOptions(IReadOnlyList<ImportMatchKey> Keys, bool CanMatch, bool CanDeleteExistingRows = false)
{
    public static ImportMatchOptions None { get; } = new([], false);
}

/// <summary>
/// The import sheet of the macOS app: the destination, how a delimited file is read, each field of the file against a
/// column (or, for a new table, the column it becomes) and the first rows as read. Changing a reading option reads
/// the file again and keeps every choice made for the fields still there.
/// </summary>
internal sealed class ImportMappingDialog
{
    private static readonly ImportWriteMode[] WriteModes = [ImportWriteMode.Insert, ImportWriteMode.Update, ImportWriteMode.Upsert, ImportWriteMode.InsertSkippingExisting];

    // One store for the process, so two windows importing at once fold their mappings into one file instead of the
    // later write dropping the earlier one.
    private static readonly Lazy<ImportMappingStore> MappingStore = new(() => new ImportMappingStore(AppPaths.Default));

    /// <summary>The process's one mapping store, which the app host also prunes when a connection is deleted.</summary>
    internal static ImportMappingStore Mappings => MappingStore.Value;

    private static readonly (string Name, char? Value)[] Delimiters =
    [
        (Strings.Get("Import/DelimiterDetect"), null),
        (Strings.Get("Import/DelimiterComma"), ','),
        (Strings.Get("Import/DelimiterSemicolon"), ';'),
        (Strings.Get("Import/DelimiterTab"), '\t'),
        (Strings.Get("Import/DelimiterPipe"), '|'),
    ];

    private readonly Func<CsvImportOptions, Task<ImportPreview>> _readPreview;
    private readonly ImportFileFormat _format;
    private readonly ObjectName _existingTable;
    private readonly Func<ImportFieldType, string> _proposeType;
    private readonly IReadOnlyList<string> _commonTypes;
    private readonly NewTableDraft _draft = new();
    private readonly ImportMapping _mapping;

    private readonly RadioButtons _destination = new() { Header = Strings.Get("Import/ImportIntoHeader"), MaxColumns = 2 };
    private readonly TextBox _newTableName = new() { PlaceholderText = "table_name", MinWidth = 220, IsEnabled = false };
    private readonly ComboBox _delimiter = new() { Header = Strings.Get("Import/DelimiterHeader"), MinWidth = 140 };
    private readonly CheckBox _hasHeader = new() { Content = Strings.Get("Import/FirstRowIsHeader"), IsChecked = true };
    private readonly CheckBox _trim = new() { Content = Strings.Get("Import/TrimSpaces") };
    private readonly TextBox _nullText = new() { Header = Strings.Get("Import/NullTextHeader"), PlaceholderText = "NULL", Width = 110 };
    private readonly CheckBox _includeAll = new() { Content = Strings.Get("Import/ImportAllFields"), IsThreeState = false };
    private readonly StackPanel _rows = new() { Spacing = 4 };
    private readonly DataGridView _previewGrid = new() { Height = 170 };
    private readonly TextBlock _previewNote = new() { Opacity = 0.7 };
    private readonly InfoBar _problem = new() { Severity = InfoBarSeverity.Warning, IsClosable = false };
    private readonly DropDownButton _match = new() { Content = Strings.Get("Import/MatchColumns") };
    private readonly MenuFlyoutItem _useSaved = new() { Text = Strings.Get("Import/UseSavedMapping") };
    private readonly TextBlock _savedNote = new() { Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly ComboBox _writeMode = new() { Header = Strings.Get("Import/ImportAsHeader"), MinWidth = 200 };
    private readonly ComboBox _matchKey = new() { Header = Strings.Get("Import/MatchOnHeader"), MinWidth = 220 };
    private readonly CheckBox _deleteExisting = new() { Content = Strings.Get("Import/DeleteExistingRows"), VerticalAlignment = VerticalAlignment.Bottom };
    private readonly ImportMatchOptions _matching;
    private ImportPreview _preview;
    private CsvImportOptions? _lastOptions;
    private ContentDialog? _dialog;
    private bool _building;

    private ImportMappingDialog(
        ImportPreview preview, ImportFileFormat format, CsvImportOptions csvOptions, Func<CsvImportOptions, Task<ImportPreview>> readPreview,
        ObjectName existingTable, IReadOnlyList<ImportTargetColumn> columns, bool canCreateTable, string proposedTableName,
        Func<ImportFieldType, string> proposeType, IReadOnlyList<string> commonTypes,
        IReadOnlyDictionary<string, ImportMappingOverride> savedMapping, ImportMatchOptions matching)
    {
        _preview = preview;
        _format = format;
        _readPreview = readPreview;
        _existingTable = existingTable;
        _proposeType = proposeType;
        _commonTypes = commonTypes;
        _mapping = new ImportMapping(preview.Fields, columns, savedMapping);
        _matching = matching;
        _draft.Load(preview.Fields, proposeType);

        _destination.Items.Add(Strings.Format("Import/ExistingTable", existingTable.Name));
        _destination.Items.Add(Strings.Get("Import/NewTable"));
        _destination.SelectedIndex = 0;
        _destination.Visibility = canCreateTable ? Visibility.Visible : Visibility.Collapsed;
        _newTableName.Text = proposedTableName;
        AutomationProperties.SetName(_newTableName, Strings.Get("Import/NewTableName"));
        _destination.SelectionChanged += (_, _) =>
        {
            _newTableName.IsEnabled = IsNewTable;
            SyncWriteControls();
            BuildRows();
        };

        foreach (var mode in WriteModes)
        {
            _writeMode.Items.Add(ModeName(mode));
        }

        _writeMode.SelectedIndex = 0;
        ToolTipService.SetToolTip(_writeMode, Strings.Get("Import/WriteModeToolTip"));
        foreach (var key in matching.Keys)
        {
            _matchKey.Items.Add(KeyName(key));
        }

        _matchKey.SelectedIndex = matching.Keys.Count > 0 ? 0 : -1;
        _matchKey.IsEnabled = matching.Keys.Count > 0;
        _writeMode.SelectionChanged += (_, _) =>
        {
            SyncWriteControls();
            Validate();
        };
        _matchKey.SelectionChanged += (_, _) => Validate();
        _newTableName.TextChanged += (_, _) => Validate();
        ToolTipService.SetToolTip(_deleteExisting, Strings.Get("Import/DeleteExistingRowsToolTip"));

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
        var byName = new MenuFlyoutItem { Text = Strings.Get("Import/MatchByName") };
        byName.Click += (_, _) =>
        {
            _mapping.MatchByName();
            BuildRows();
        };
        var byPosition = new MenuFlyoutItem { Text = Strings.Get("Import/MatchByPosition") };
        byPosition.Click += (_, _) =>
        {
            _mapping.MatchByPosition();
            BuildRows();
        };
        _useSaved.Click += (_, _) =>
        {
            _mapping.UseSavedMapping();
            BuildRows();
        };
        matchMenu.Items.Add(byName);
        matchMenu.Items.Add(byPosition);
        if (savedMapping.Count > 0)
        {
            matchMenu.Items.Add(new MenuFlyoutSeparator());
            matchMenu.Items.Add(_useSaved);
        }

        matchMenu.Opening += (_, _) => _useSaved.IsEnabled = _mapping.CanUseSavedMapping;
        _match.Flyout = matchMenu;
        _savedNote.Text = Strings.Format("Import/RestoredSavedMapping", existingTable.Name);
        SyncWriteControls();
    }

    private ImportWriteMode WriteMode => WriteModes[Math.Max(0, _writeMode.SelectedIndex)];

    private ImportMatchKey? MatchKey =>
        _matchKey.SelectedIndex >= 0 && _matchKey.SelectedIndex < _matching.Keys.Count ? _matching.Keys[_matchKey.SelectedIndex] : null;

    private bool OffersWriteModes => _matching.CanMatch && !IsNewTable;

    private static string ModeName(ImportWriteMode mode) => mode switch
    {
        ImportWriteMode.Update => Strings.Get("Import/WriteModeUpdate"),
        ImportWriteMode.Upsert => Strings.Get("Import/WriteModeUpsert"),
        ImportWriteMode.InsertSkippingExisting => Strings.Get("Import/WriteModeSkipExisting"),
        _ => Strings.Get("Import/WriteModeInsert"),
    };

    private static string KeyName(ImportMatchKey key)
    {
        var columns = string.Join(", ", key.Columns);
        return key.IndexName is { } index ? Strings.Format("Import/MatchKeyIndex", index, columns) : Strings.Format("Import/MatchKeyPrimary", columns);
    }

    private static string WritingProblemText(ImportRowWritingProblem problem) => problem.Kind switch
    {
        ImportRowWritingProblemKind.NoKey => Strings.Get("Import/ProblemNoKey"),
        ImportRowWritingProblemKind.UnmappedKeyColumns => Strings.Format("Import/ProblemUnmappedKey", string.Join(", ", problem.Columns)),
        _ => Strings.Get("Import/ProblemNothingToUpdate"),
    };

    /// <summary>
    /// Only an existing table has rows to match, and only a connection that can count keys offers the modes that do.
    /// Emptying the table first is offered only for Insert, as on macOS, since no row would be left to match.
    /// </summary>
    private void SyncWriteControls()
    {
        _writeMode.Visibility = OffersWriteModes ? Visibility.Visible : Visibility.Collapsed;
        _matchKey.Visibility = OffersWriteModes && WriteMode.MatchesExistingRows() ? Visibility.Visible : Visibility.Collapsed;
        _deleteExisting.Visibility = _matching.CanDeleteExistingRows && !IsNewTable ? Visibility.Visible : Visibility.Collapsed;
        _deleteExisting.IsEnabled = !OffersWriteModes || !WriteMode.MatchesExistingRows();
        if (!_deleteExisting.IsEnabled)
        {
            _deleteExisting.IsChecked = false;
        }
    }

    private bool DeletesExistingRows => _deleteExisting.Visibility == Visibility.Visible && _deleteExisting.IsEnabled && _deleteExisting.IsChecked == true;

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
        bool canCreateTable, Func<ImportFieldType, string> proposeType, IReadOnlyList<string> commonTypes,
        ImportMappingScope? mappingScope = null, ImportMatchOptions? matching = null)
    {
        var proposed = Path.GetFileNameWithoutExtension(fileName.EndsWith(".gz", StringComparison.OrdinalIgnoreCase) ? fileName[..^3] : fileName);
        var saved = await LoadSavedMappingAsync(mappingScope);
        var view = new ImportMappingDialog(
            preview, format, csvOptions, readPreview, existingTable, columns, canCreateTable, proposed, proposeType, commonTypes, saved, matching ?? ImportMatchOptions.None);
        var dialog = dialogs.Create(Strings.Format("Import/ImportFileTitle", fileName), view.BuildContent(), Strings.Get("Common/Import"), Strings.Get("Common/Cancel"));

        // The field list, the new table's settings and the preview need more room than a ContentDialog's default 548 pixels.
        dialog.Resources["ContentDialogMaxWidth"] = 1040.0;
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        view._dialog = dialog;
        view.BuildRows();
        if (await dialogs.ShowAsync(dialog) != ContentDialogResult.Primary || view.CurrentProblem() is not null)
        {
            return null;
        }

        if (view.IsNewTable)
        {
            return new ImportPlan(
                ImportDestination.NewTable, new ObjectName(existingTable.Schema, view._newTableName.Text.Trim()), view.CsvOptions,
                view._draft.CreateRowBuilder(), view._draft.Definition(), ImportRowWriting.Insert);
        }

        await view.RememberMappingAsync(mappingScope);
        var writing = view.OffersWriteModes ? view._mapping.RowWriting(view.WriteMode, view.MatchKey) : ImportRowWriting.Insert;
        return new ImportPlan(
            ImportDestination.ExistingTable, existingTable, view.CsvOptions, view._mapping.CreateRowBuilder(), [], writing with { DeleteExistingRows = view.DeletesExistingRows });
    }

    /// <summary>A store that cannot be read only means nothing is restored; the import itself goes on.</summary>
    private static async Task<IReadOnlyDictionary<string, ImportMappingOverride>> LoadSavedMappingAsync(ImportMappingScope? scope)
    {
        if (scope is null)
        {
            return new Dictionary<string, ImportMappingOverride>();
        }

        try
        {
            return await Task.Run(() => MappingStore.Value.OverridesAsync(scope));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return new Dictionary<string, ImportMappingOverride>();
        }
    }

    /// <summary>Called as the import starts, whether or not it then succeeds: a mapping built by hand is the costliest part to redo.</summary>
    private async Task RememberMappingAsync(ImportMappingScope? scope)
    {
        if (scope is null)
        {
            return;
        }

        var overrides = _mapping.Overrides();
        var fields = _mapping.FieldNames;
        try
        {
            await Task.Run(() => MappingStore.Value.RememberAsync(scope, overrides, fields));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Losing the remembered mapping costs a few clicks next time; it must not stop the import the user asked for.
        }
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

        var writing = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        writing.Children.Add(_writeMode);
        writing.Children.Add(_matchKey);
        writing.Children.Add(_deleteExisting);
        root.Children.Add(writing);

        if (_format == ImportFileFormat.Csv)
        {
            var options = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
            options.Children.Add(_delimiter);
            _hasHeader.VerticalAlignment = _trim.VerticalAlignment = VerticalAlignment.Bottom;
            options.Children.Add(_hasHeader);
            options.Children.Add(_trim);
            options.Children.Add(_nullText);
            ToolTipService.SetToolTip(_nullText, Strings.Get("Import/NullTextToolTip"));
            root.Children.Add(options);
        }

        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new GridColumn { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new GridColumn { Width = GridLength.Auto });
        toolbar.Children.Add(_includeAll);
        _savedNote.Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"];
        Grid.SetColumn(_savedNote, 1);
        toolbar.Children.Add(_savedNote);
        Grid.SetColumn(_match, 2);
        toolbar.Children.Add(_match);
        root.Children.Add(toolbar);
        root.Children.Add(new ScrollViewer { Content = _rows, MaxHeight = 260, Padding = new Thickness(0, 0, 12, 0) });

        var previewHeader = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        previewHeader.Children.Add(new TextBlock { Text = Strings.Get("Import/FirstRows"), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
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
            _problem.Title = Strings.Get("Import/CannotReadFileTitle");
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
            _savedNote.Visibility = !IsNewTable && _mapping.ShowsSavedMapping ? Visibility.Visible : Visibility.Collapsed;
            _includeAll.Content = IsNewTable ? Strings.Get("Import/CreateAllColumns") : Strings.Get("Import/ImportAllFields");
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
        string[] labels = IsNewTable
            ? ["", Strings.Get("Import/HeaderField"), Strings.Get("Import/HeaderColumn"), Strings.Get("Common/Type"), Strings.Get("Import/HeaderKey"), Strings.Get("Import/HeaderNull"), Strings.Get("Import/HeaderDefault")]
            : ["", Strings.Get("Import/HeaderField"), Strings.Get("Import/HeaderColumn"), Strings.Get("Common/Type")];
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
        AutomationProperties.SetName(include, Strings.Format("Import/ImportFieldName", field.Name));
        var target = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(target, Strings.Format("Import/ColumnForFieldName", field.Name));
        target.Items.Add(Strings.Get("Import/Skip"));
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
        AutomationProperties.SetName(include, Strings.Format("Import/CreateFieldName", column.Field.Name));
        var name = new TextBox { Text = settings.Name };
        AutomationProperties.SetName(name, Strings.Format("Import/ColumnNameForFieldName", column.Field.Name));
        var type = new ComboBox { IsEditable = true, HorizontalAlignment = HorizontalAlignment.Stretch, ItemsSource = TypeChoices(settings.Type), Text = settings.Type };
        AutomationProperties.SetName(type, Strings.Format("Import/TypeOfFieldName", column.Field.Name));
        var key = new CheckBox { IsChecked = settings.IsPrimaryKey, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(key, Strings.Format("Import/PrimaryKeyFieldName", column.Field.Name));
        var nullable = new CheckBox { IsChecked = settings.IsNullable, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(nullable, Strings.Format("Import/AcceptsNullFieldName", column.Field.Name));
        var defaultValue = new TextBox { Text = settings.DefaultValue, PlaceholderText = Strings.Get("Import/DefaultSqlPlaceholder") };
        AutomationProperties.SetName(defaultValue, Strings.Format("Import/DefaultSqlFieldName", column.Field.Name));
        ToolTipService.SetToolTip(defaultValue, Strings.Get("Import/DefaultSqlToolTip"));

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
        var columns = _preview.Fields.Select(f => new ResultColumn(f.Name, TableNames.FieldType(f.InferredType), typeof(object))).ToArray();
        _previewGrid.Source = new ResultGridSource(new ResultSet(columns, [.. _preview.Rows]));
        _previewNote.Text = Strings.Format("Import/PreviewNote", Strings.Plural("Import/RowsShown", _preview.Rows.Count), Strings.Plural("Import/TypesFromRows", _preview.SampledRows));
    }

    private string? CurrentProblem()
    {
        if (_preview.Fields.Count == 0)
        {
            return Strings.Get("Import/NoFields");
        }

        if (!IsNewTable)
        {
            if (_mapping.Problem is { } mappingProblem)
            {
                return mappingProblem;
            }

            return OffersWriteModes && _mapping.RowWritingProblem(WriteMode, MatchKey) is { } writingProblem ? WritingProblemText(writingProblem) : null;
        }

        return string.IsNullOrWhiteSpace(_newTableName.Text) ? Strings.Get("Import/EnterNewTableName") : _draft.Problem;
    }

    private void Validate()
    {
        var problem = CurrentProblem();
        _problem.Title = problem is null ? string.Empty : Strings.Get("Import/CannotImportYetTitle");
        _problem.Message = problem ?? string.Empty;
        _problem.IsOpen = problem is not null;
        if (_dialog is not null)
        {
            _dialog.IsPrimaryButtonEnabled = problem is null;
        }
    }
}
