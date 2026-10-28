using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Helpers;
using TablePro.Core.Plans;

namespace TablePro.App.Controls;

/// <summary>
/// This run against the tab's previous one. A mode of the plan view rather than a dialog: the point of comparing is to
/// change the query or the schema and run it again, which a modal window would forbid. It leads with the verdict,
/// then the plan-wide numbers, then every step that was added, removed or changed.
/// </summary>
public sealed partial class QueryPlanComparisonView : UserControl
{
    private readonly StackPanel _content = new() { Spacing = 14, Padding = new Thickness(16, 12, 16, 16) };
    private QueryPlanCapture? _baseline;
    private QueryPlanCapture? _current;

    public QueryPlanComparisonView()
    {
        Content = new ScrollViewer { Content = _content };
        AutomationProperties.SetName(this, "Plan comparison");
        ActualThemeChanged += (_, _) => Build();
    }

    public void Show(QueryPlanCapture? baseline, QueryPlanCapture current)
    {
        _baseline = baseline;
        _current = current;
        Build();
    }

    private void Build()
    {
        _content.Children.Clear();
        if (_current is not { } current)
        {
            return;
        }

        if (_baseline is not { } baseline)
        {
            _content.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = "Nothing to compare yet", Message = "Explain again after changing the query or the schema, and this run becomes the baseline." });
            return;
        }

        _content.Children.Add(Caption(string.Create(CultureInfo.CurrentCulture, $"Baseline from {baseline.CapturedAt.ToLocalTime():T}{(baseline.Analyze ? ", analyzed" : string.Empty)}, current from {current.CapturedAt.ToLocalTime():T}{(current.Analyze ? ", analyzed" : string.Empty)}")));
        if (!string.Equals(Squash(baseline.Subject), Squash(current.Subject), StringComparison.Ordinal))
        {
            _content.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = "The baseline explained a different statement", Message = Squash(baseline.Subject) });
        }

        if (baseline.Plan is { } before && current.Plan is { } after)
        {
            ShowDiff(QueryPlanDiff.Compare(before, after));
        }
        else
        {
            ShowText(baseline.RawText, current.RawText);
        }
    }

    private void ShowDiff(QueryPlanDiff diff)
    {
        var verdict = diff.Verdict;
        _content.Children.Add(new InfoBar
        {
            IsOpen = true,
            IsClosable = false,
            Title = verdict.Headline,
            Severity = verdict.Kind switch
            {
                QueryPlanVerdictKind.Slower => InfoBarSeverity.Error,
                QueryPlanVerdictKind.Faster => InfoBarSeverity.Success,
                QueryPlanVerdictKind.Unchanged => InfoBarSeverity.Informational,
                _ => InfoBarSeverity.Warning,
            },
        });

        var summary = new Grid { ColumnSpacing = 18, RowSpacing = 6 };
        foreach (var width in (ReadOnlySpan<double>)[150, 120, 120, 160])
        {
            summary.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(width) });
        }

        AddRow(summary, 0, true, "Metric", "Baseline", "Current", "Change");
        for (var i = 0; i < diff.Summary.Count; i++)
        {
            var change = diff.Summary[i];
            AddRow(
                summary,
                i + 1,
                false,
                change.Field.Title,
                QueryPlanValueFormatter.Format(change.Before, change.Field.Unit),
                QueryPlanValueFormatter.Format(change.After, change.Field.Unit),
                QueryPlanValueFormatter.Change(change) ?? QueryPlanValueFormatter.Absent);
        }

        AutomationProperties.SetName(summary, "Plan summary");
        _content.Children.Add(summary);

        _content.Children.Add(new TextBlock { Text = "Step changes", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
        if (diff.NodeChanges.Count == 0)
        {
            _content.Children.Add(Caption("No step changed."));
            return;
        }

        var list = new StackPanel { Spacing = 2 };
        foreach (var change in diff.NodeChanges)
        {
            list.Children.Add(ChangeRow(change));
        }

        _content.Children.Add(list);
    }

    private Border ChangeRow(QueryPlanNodeChange change)
    {
        var (glyph, label, brushKey) = QueryPlanStyles.Change(change.Kind);
        var tint = ThemeResources.Brush(this, brushKey);
        var row = new Grid { ColumnSpacing = 10 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(18) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.Children.Add(new TextBlock { Text = glyph, FontWeight = Microsoft.UI.Text.FontWeights.Bold, Foreground = tint, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"] });

        var body = new StackPanel { Spacing = 2 };
        var title = new TextBlock { TextWrapping = TextWrapping.Wrap };
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = label + "  ", Foreground = tint, FontSize = 12 });
        title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = change.Operation, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        if (change.RelationName is { } relation)
        {
            title.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = "  " + relation, Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush") });
        }

        body.Children.Add(title);
        foreach (var field in change.FieldChanges)
        {
            body.Children.Add(new TextBlock
            {
                Text = $"{field.Field.Title}: {QueryPlanValueFormatter.Format(field.Before, field.Field.Unit)} → {QueryPlanValueFormatter.Format(field.After, field.Field.Unit)}",
                FontSize = 12,
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
                FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"],
                Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
            });
        }

        Grid.SetColumn(body, 1);
        row.Children.Add(body);
        var border = new Border { Child = row, Padding = new Thickness(0, 6, 0, 6), BorderBrush = ThemeResources.Brush(this, "DividerStrokeColorDefaultBrush"), BorderThickness = new Thickness(0, 0, 0, 1) };
        AutomationProperties.SetName(border, $"{label}: {change.Title}");
        return border;
    }

    private void ShowText(string baseline, string current)
    {
        _content.Children.Add(new InfoBar { IsOpen = true, IsClosable = false, Severity = InfoBarSeverity.Informational, Title = "Compared as text", Message = "One of the plans could not be read as a tree, so the two runs are compared line by line." });
        var lines = PlanTextDiff.Lines(baseline, current);
        var text = new TextBlock { FontSize = 12, IsTextSelectionEnabled = true, FontFamily = (FontFamily)Application.Current.Resources["CodeFontFamily"] };
        if (lines is null)
        {
            text.Text = "Baseline\n" + baseline + "\n\nCurrent\n" + current;
        }
        else
        {
            foreach (var (kind, line) in lines)
            {
                var run = new Microsoft.UI.Xaml.Documents.Run
                {
                    Text = (kind switch { PlanTextChangeKind.Added => "+ ", PlanTextChangeKind.Removed => "− ", _ => "  " }) + line + "\n",
                };
                if (kind != PlanTextChangeKind.Same)
                {
                    run.Foreground = ThemeResources.Brush(this, kind == PlanTextChangeKind.Added ? "SystemFillColorSuccessBrush" : "SystemFillColorCriticalBrush");
                }

                text.Inlines.Add(run);
            }
        }

        _content.Children.Add(text);
    }

    private void AddRow(Grid grid, int row, bool header, params string[] cells)
    {
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var column = 0; column < cells.Length; column++)
        {
            var text = new TextBlock { Text = cells[column], FontSize = header ? 12 : 13, TextTrimming = TextTrimming.CharacterEllipsis };
            if (header)
            {
                text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
                text.Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush");
            }
            else if (column == 1)
            {
                text.Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush");
            }

            Grid.SetRow(text, row);
            Grid.SetColumn(text, column);
            grid.Children.Add(text);
        }
    }

    private TextBlock Caption(string text) => new()
    {
        Text = text,
        TextWrapping = TextWrapping.Wrap,
        Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
        Foreground = ThemeResources.Brush(this, "TextFillColorSecondaryBrush"),
    };

    private static string Squash(string sql) => string.Join(' ', sql.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}
