using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Helpers;
using TablePro.Core.Plans;
using Windows.ApplicationModel.DataTransfer;

namespace TablePro.App.Controls;

/// <summary>Everything one plan step reports, shared by the diagram and the outline: estimates, measurements, warnings, missing indexes, properties.</summary>
public sealed partial class QueryPlanDetailPane : UserControl
{
    private readonly StackPanel _content = new() { Spacing = 10, Padding = new Thickness(14, 12, 14, 14) };
    private QueryPlanNode? _node;

    public QueryPlanDetailPane()
    {
        Content = new ScrollViewer { Content = _content, HorizontalScrollMode = ScrollMode.Disabled };
        AutomationProperties.SetName(this, "Plan step details");
        ActualThemeChanged += (_, _) => Build();
        Build();
    }

    // Internal so the XAML type table does not reflect over it and try to construct a node.
    internal QueryPlanNode? Node
    {
        get => _node;
        set
        {
            _node = value;
            Build();
        }
    }

    private void Build()
    {
        _content.Children.Clear();
        if (_node is not { } node)
        {
            var empty = new StackPanel { Spacing = 6, Margin = new Thickness(0, 40, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };
            empty.Children.Add(new FontIcon { Glyph = "", FontSize = 24, Foreground = ThemeResources.Brush(this, "TextFillColorTertiaryBrush") });
            empty.Children.Add(new TextBlock { Text = "No step selected", HorizontalAlignment = HorizontalAlignment.Center, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
            empty.Children.Add(new TextBlock { Text = "Select a step in the plan to see what it does.", TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], Foreground = ThemeResources.Brush(this, "TextFillColorTertiaryBrush") });
            _content.Children.Add(empty);
            return;
        }

        var header = new Grid { ColumnSpacing = 8 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        if (node.Severity is { } severity)
        {
            header.Children.Add(QueryPlanStyles.Badge(this, severity, 12));
        }

        var title = new TextBlock { Text = node.Operation, Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"], FontSize = 16, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        Grid.SetColumn(title, 1);
        header.Children.Add(title);
        var copy = CopyButton("Copy step details", () => QueryPlanLabels.Text(node));
        Grid.SetColumn(copy, 2);
        header.Children.Add(copy);
        _content.Children.Add(header);

        var estimates = Section(null);
        Row(estimates, "Table", node.Relation);
        Row(estimates, "Schema", node.Schema);
        Row(estimates, "Alias", node.Alias is { } alias && alias != node.Relation ? alias : null);
        Row(estimates, "Cost", node.CostRangeText(2));
        Row(estimates, "Share", node.CostFraction is { } share ? share.ToString("P1", CultureInfo.CurrentCulture) : null);
        Row(estimates, "Rows", node.EstimatedRows?.ToString("N0", CultureInfo.CurrentCulture));
        Row(estimates, "Width", node.EstimatedWidth is > 0 ? node.EstimatedWidth.Value.ToString("N0", CultureInfo.CurrentCulture) : null);
        AddIfAny(estimates);

        if (node.ActualTotalTime is not null || node.ActualRows is not null)
        {
            var actual = Section("Actual");
            Row(actual, "Time", node.ActualTotalTime is { } time ? QueryPlanLabels.Milliseconds(time) : null);
            Row(actual, "Startup", node.ActualStartupTime is { } startup ? QueryPlanLabels.Milliseconds(startup) : null);
            Row(actual, "Rows", node.ActualRows?.ToString("N0", CultureInfo.CurrentCulture));
            Row(actual, "Loops", node.ActualLoops is > 1 ? node.ActualLoops.Value.ToString("N0", CultureInfo.CurrentCulture) : null);
            Row(actual, "Total rows", node.ActualLoops is > 1 ? node.TotalActualRows?.ToString("N0", CultureInfo.CurrentCulture) : null);
            AddIfAny(actual);
        }

        if (node.Warnings.Count > 0)
        {
            var warnings = new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Warning, Title = node.Warnings.Count == 1 ? "Warning" : "Warnings", Message = string.Join("\n", node.Warnings) };
            _content.Children.Add(warnings);
        }

        foreach (var index in node.MissingIndexes)
        {
            var missing = Section(index.Impact is { } impact ? string.Create(CultureInfo.CurrentCulture, $"Missing index, estimated impact {impact:0.#}%") : "Missing index");
            var line = new Grid { ColumnSpacing = 6 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.Children.Add(new TextBlock { Text = index.CreateStatement, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontSize = 12, FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["CodeFontFamily"] });
            var copyIndex = CopyButton("Copy CREATE INDEX", () => index.CreateStatement);
            Grid.SetColumn(copyIndex, 1);
            line.Children.Add(copyIndex);
            missing.Children.Add(line);
            _content.Children.Add(missing);
        }

        var properties = QueryPlanLabels.VisibleProperties(node);
        if (properties.Count > 0)
        {
            var details = Section("Details");
            foreach (var (key, value) in properties)
            {
                Row(details, key, value);
            }

            _content.Children.Add(details);
        }
    }

    private StackPanel Section(string? title)
    {
        var section = new StackPanel { Spacing = 4 };
        if (title is not null)
        {
            section.Children.Add(new TextBlock { Text = title, Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"], FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"), Margin = new Thickness(0, 4, 0, 2) });
        }

        return section;
    }

    private void AddIfAny(StackPanel section)
    {
        if (section.Children.Any(c => c is Grid))
        {
            _content.Children.Add(section);
        }
    }

    private void Row(StackPanel section, string label, string? value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return;
        }

        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock { Text = label, FontSize = 12, TextAlignment = TextAlignment.Right, TextWrapping = TextWrapping.Wrap, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
        var text = new TextBlock { Text = value, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = (Microsoft.UI.Xaml.Media.FontFamily)Application.Current.Resources["CodeFontFamily"] };
        Grid.SetColumn(text, 1);
        row.Children.Add(text);
        section.Children.Add(row);
    }

    private static Button CopyButton(string name, Func<string> text)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = "", FontSize = 14 },
            Style = (Style)Application.Current.Resources["ToolbarButtonStyle"],
            VerticalAlignment = VerticalAlignment.Top,
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) =>
        {
            var package = new DataPackage();
            package.SetText(text());
            Clipboard.SetContent(package);
        };
        return button;
    }
}
