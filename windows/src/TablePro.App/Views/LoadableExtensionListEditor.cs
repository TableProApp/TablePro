using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Services;
using TablePro.Core.Connections;

namespace TablePro.App.Views;

/// <summary>
/// The ordered list of SQLite extension libraries a connection loads, edited in place in the connection form. Add
/// opens a file picker, the only way a row is created; a row's path and entry point are then edited in place, and
/// each row moves up, down or out with its own buttons.
/// </summary>
internal sealed class LoadableExtensionListEditor
{
    private const string PathPlaceholder = "C:\\Tools\\mod_spatialite.dll";

    private readonly DialogService _dialogs;
    private readonly List<(TextBox Path, TextBox EntryPoint)> _rows = [];
    private readonly StackPanel _list = new() { Spacing = 6 };
    private readonly TextBlock _empty;
    private readonly InfoBar _unreadable = new()
    {
        Severity = InfoBarSeverity.Warning,
        IsClosable = false,
        IsOpen = false,
        Message = Strings.Get("Extensions/Unreadable"),
    };

    private HashSet<LoadableExtension> _initial = [];
    private string? _unreadableValue;

    public LoadableExtensionListEditor(DialogService dialogs)
    {
        _dialogs = dialogs;
        _empty = Caption(Strings.Get("Extensions/NoExtensions"));
        var add = new Button
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8,
                Children = { new FontIcon { Glyph = "\xE710", FontSize = 14 }, new TextBlock { Text = Strings.Get("Extensions/AddExtension") } },
            },
        };
        add.Click += async (_, _) => await AddAsync();

        Root = new StackPanel
        {
            Spacing = 8,
            Children =
            {
                new TextBlock { Text = Strings.Get("Extensions/Header") },
                _list,
                _empty,
                add,
                _unreadable,
                Caption(Strings.Get("Extensions/Footer")),
            },
        };
    }

    public FrameworkElement Root { get; }

    /// <summary>The rows as they stand, empty paths included, so the form can refuse them.</summary>
    public IReadOnlyList<LoadableExtension> Extensions => [.. _rows.Select(r => new LoadableExtension(r.Path.Text, r.EntryPoint.Text))];

    /// <summary>
    /// The rows added or changed since the form opened. Only these were chosen on this PC, so saving approves them;
    /// an imported list saved untouched approves nothing.
    /// </summary>
    public IReadOnlyList<LoadableExtension> Edited => [.. Extensions.Where(e => !_initial.Contains(e))];

    /// <summary>The value to store: the rows, or a saved value that did not read, kept until the list is edited.</summary>
    public string Stored => _unreadableValue ?? LoadableExtensionList.Encode(Extensions);

    /// <summary>Why the rows cannot be saved, or null.</summary>
    public string? Problem
    {
        get
        {
            if (_unreadableValue is not null)
            {
                return null;
            }

            try
            {
                LoadableExtensionPreflight.Validate(Extensions);
                return null;
            }
            catch (LoadableExtensionException ex)
            {
                return ExtensionNames.Reason(ex);
            }
        }
    }

    public void Load(string? stored)
    {
        _rows.Clear();
        _list.Children.Clear();
        _unreadableValue = null;
        IReadOnlyList<LoadableExtension> extensions;
        try
        {
            extensions = LoadableExtensionList.Decode(stored);
        }
        catch (LoadableExtensionException)
        {
            extensions = [];
            _unreadableValue = stored;
        }

        _initial = [.. extensions];
        foreach (var item in extensions)
        {
            AddRow(item.Path, item.EntryPoint);
        }

        Refresh();
    }

    private async Task AddAsync()
    {
        var file = await _dialogs.PickOpenFileAsync(".dll", "*");
        if (file is null)
        {
            return;
        }

        // A list that did not read is replaced by the first edit, as the warning says.
        _unreadableValue = null;
        AddRow(file.Path, null);
        Refresh();
    }

    private void AddRow(string path, string? entryPoint)
    {
        var pathBox = new TextBox { Text = path, PlaceholderText = PathPlaceholder };
        AutomationProperties.SetName(pathBox, Strings.Get("Extensions/FileLabel"));
        var entryBox = new TextBox { Text = entryPoint ?? string.Empty, PlaceholderText = Strings.Get("Extensions/EntryPointPlaceholder"), Width = 150 };
        AutomationProperties.SetName(entryBox, Strings.Get("Extensions/EntryPointLabel"));
        ToolTipService.SetToolTip(entryBox, Strings.Get("Extensions/EntryPointTooltip"));
        var row = (pathBox, entryBox);
        _rows.Add(row);

        var grid = new Grid { ColumnSpacing = 4 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 4; i++)
        {
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        }

        Place(grid, pathBox, 0);
        Place(grid, entryBox, 1);
        Place(grid, IconButton("\xE70E", Strings.Get("Extensions/MoveUp"), () => Move(row, -1)), 2);
        Place(grid, IconButton("\xE70D", Strings.Get("Extensions/MoveDown"), () => Move(row, 1)), 3);
        Place(grid, IconButton("\xE74D", Strings.Get("Extensions/RemoveExtension"), () => Remove(row)), 4);
        _list.Children.Add(grid);
    }

    private void Move((TextBox Path, TextBox EntryPoint) row, int offset)
    {
        var index = _rows.IndexOf(row);
        var target = index + offset;
        if (index < 0 || target < 0 || target >= _rows.Count)
        {
            return;
        }

        (_rows[index], _rows[target]) = (_rows[target], _rows[index]);
        var element = _list.Children[index];
        _list.Children.RemoveAt(index);
        _list.Children.Insert(target, element);
    }

    private void Remove((TextBox Path, TextBox EntryPoint) row)
    {
        var index = _rows.IndexOf(row);
        if (index >= 0)
        {
            _rows.RemoveAt(index);
            _list.Children.RemoveAt(index);
            Refresh();
        }
    }

    private void Refresh()
    {
        _empty.Visibility = _rows.Count == 0 && _unreadableValue is null ? Visibility.Visible : Visibility.Collapsed;
        _unreadable.IsOpen = _unreadableValue is not null;
    }

    private static Button IconButton(string glyph, string name, Action action)
    {
        var button = new Button { Content = new FontIcon { Glyph = glyph, FontSize = 14 }, Padding = new Thickness(8), VerticalAlignment = VerticalAlignment.Stretch };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => action();
        return button;
    }

    private static void Place(Grid grid, FrameworkElement element, int column)
    {
        Grid.SetColumn(element, column);
        grid.Children.Add(element);
    }

    private static TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
    };
}
