using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Views;

// A results pane's rows as JSON, as macOS's JSON mode: the text, or a tree whose rows open on demand.
internal sealed partial class JsonResultView : UserControl
{
    private readonly SelectorBar _modes = new() { Margin = new Thickness(4, 0, 4, 0) };
    private readonly SelectorBarItem _textItem = new() { IsSelected = true };
    private readonly SelectorBarItem _treeItem = new();
    private readonly TextBlock _line = new()
    {
        VerticalAlignment = VerticalAlignment.Center,
        TextTrimming = TextTrimming.CharacterEllipsis,
    };

    private readonly Button _copy = new() { IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBox _text = new()
    {
        Margin = new Thickness(8, 0, 8, 8),
        IsReadOnly = true,
        AcceptsReturn = true,
        IsSpellCheckEnabled = false,
        TextWrapping = TextWrapping.Wrap,
        FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
    };

    private readonly TreeView _tree = new()
    {
        Margin = new Thickness(4, 0, 4, 8),
        FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
        Visibility = Visibility.Collapsed,
    };

    // The model behind each node the tree holds, for its children when it opens.
    private readonly Dictionary<TreeViewNode, JsonTreeNode> _nodes = [];
    private RowsJson? _json;
    private JsonTree? _parsed;
    private bool _treeFilled;

    public JsonResultView()
    {
        _textItem.Text = Strings.Get("JsonTextMode");
        _treeItem.Text = Strings.Get("JsonTreeMode");
        AutomationProperties.SetAutomationId(_textItem, "JsonTextMode");
        AutomationProperties.SetAutomationId(_treeItem, "JsonTreeMode");
        AutomationProperties.SetAutomationId(_modes, "JsonModes");
        AutomationProperties.SetName(_modes, Strings.Get("JsonModes"));
        _modes.Items.Add(_textItem);
        _modes.Items.Add(_treeItem);
        _modes.SelectionChanged += (_, _) => ShowMode();

        _line.Style = (Style)Application.Current.Resources["SecondaryCaptionTextBlockStyle"];
        AutomationProperties.SetAutomationId(_line, "JsonRowsLine");
        AutomationProperties.SetLiveSetting(_line, AutomationLiveSetting.Polite);

        _copy.Content = Strings.Get("CopyJson");
        AutomationProperties.SetAutomationId(_copy, "CopyJson");
        _copy.Click += (_, _) => Copy();

        ScrollViewer.SetVerticalScrollBarVisibility(_text, ScrollBarVisibility.Auto);
        AutomationProperties.SetAutomationId(_text, "JsonText");
        AutomationProperties.SetName(_text, Strings.Get("JsonTextName"));
        AutomationProperties.SetAutomationId(_tree, "JsonTree");
        AutomationProperties.SetName(_tree, Strings.Get("JsonTreeName"));
        _tree.Expanding += OnExpanding;

        var bar = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 0, 8, 0) };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_line, 1);
        Grid.SetColumn(_copy, 2);
        bar.Children.Add(_modes);
        bar.Children.Add(_line);
        bar.Children.Add(_copy);

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(_text, 1);
        Grid.SetRow(_tree, 1);
        root.Children.Add(bar);
        root.Children.Add(_text);
        root.Children.Add(_tree);
        Content = root;
    }

    private bool ShowsTree => ReferenceEquals(_modes.SelectedItem, _treeItem);

    // For the Edit menu's Copy and Select All while the text shows.
    internal TextBox TextBox => _text;

    internal bool ShowsText => Visibility == Visibility.Visible && !ShowsTree;

    // The view owns the tree from here, and lets go of the one it showed.
    public void Show(RowsJson json, JsonTree tree)
    {
        ArgumentNullException.ThrowIfNull(json);
        ArgumentNullException.ThrowIfNull(tree);
        LetGoOfTree();
        _json = json;
        _parsed = tree;
        var (text, cut) = json.TextUpTo(CellValue.MaximumShownCharacters);
        _text.Text = text;
        _line.Text = Line(json, cut);
        _copy.IsEnabled = true;
        if (ShowsTree)
        {
            FillTree();
        }
    }

    public void ShowFailure(string message)
    {
        Clear();
        _line.Text = message;
    }

    public void Clear()
    {
        LetGoOfTree();
        _json = null;
        _text.Text = string.Empty;
        _line.Text = string.Empty;
        _copy.IsEnabled = false;
    }

    private static string Line(RowsJson json, bool cut)
    {
        var line = json.Rows == json.Total
            ? Strings.Format("JsonRows", json.Rows)
            : Strings.Format("JsonRowsOf", json.Rows, json.Total);
        if (json.Capped)
        {
            line = Strings.Format("JsonRowsCapped", line, json.Rows);
        }

        if (json.Deleted > 0)
        {
            line = Strings.Plural("JsonRowsDeleted", json.Deleted, line, json.Deleted);
        }

        return cut ? Strings.Format("JsonTextCut", line) : line;
    }

    private void ShowMode()
    {
        var tree = ShowsTree;
        _text.Visibility = tree ? Visibility.Collapsed : Visibility.Visible;
        _tree.Visibility = tree ? Visibility.Visible : Visibility.Collapsed;
        if (tree)
        {
            FillTree();
        }
    }

    // Built once per JSON, when the tree is first shown: a node per row, its fields made as it opens.
    private void FillTree()
    {
        if (_treeFilled || _parsed is not { } parsed)
        {
            return;
        }

        _treeFilled = true;
        foreach (var root in parsed.Roots)
        {
            _tree.RootNodes.Add(Node(root));
        }
    }

    private TreeViewNode Node(JsonTreeNode model)
    {
        var node = new TreeViewNode { Content = model.Text, HasUnrealizedChildren = model.ChildCount > 0 };
        _nodes.Add(node, model);
        return node;
    }

    private void OnExpanding(TreeView sender, TreeViewExpandingEventArgs args)
    {
        var node = args.Node;
        if (!node.HasUnrealizedChildren || !_nodes.TryGetValue(node, out var model))
        {
            return;
        }

        node.HasUnrealizedChildren = false;
        foreach (var child in model.Children())
        {
            node.Children.Add(Node(child));
        }
    }

    // The nodes go before the document they read, so no node opens onto a disposed one.
    private void LetGoOfTree()
    {
        _tree.RootNodes.Clear();
        _nodes.Clear();
        _treeFilled = false;
        _parsed?.Dispose();
        _parsed = null;
    }

    // The whole JSON, though the text view may show only its start.
    private void Copy()
    {
        if (_json is not { } json)
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(json.Text);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            _line.Text = Strings.Get("JsonCopyFailed");
        }
    }
}
