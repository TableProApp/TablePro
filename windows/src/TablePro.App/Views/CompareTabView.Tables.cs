using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Helpers;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Compare;

namespace TablePro.App.Views;

/// <summary>
/// The multi-table half of the tab: one row per table pair with its counts, as the macOS app's plan list, a scope
/// editor per table, and drilling into a table's rows.
/// </summary>
public sealed partial class CompareTabView
{
    private readonly Grid _planHeader = new() { ColumnSpacing = 8 };
    private readonly TextBlock _planTitle = new() { VerticalAlignment = VerticalAlignment.Center, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] };
    private readonly Grid _planList = new() { RowSpacing = 8, Visibility = Visibility.Collapsed };
    private readonly ListView _plans = new() { SelectionMode = ListViewSelectionMode.None };
    private readonly StackPanel _selectButtons = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly TextBlock _unpaired = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.7, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _plansEmpty = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.7, Text = Strings.Get("Compare/NoSharedTables"), Visibility = Visibility.Collapsed };
    private readonly List<PlanRow> _planRows = [];

    private FrameworkElement BuildPlanHeader()
    {
        var back = new Button
        {
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 6,
                Children = { new FontIcon { Glyph = "\xE72B", FontSize = 12 }, new TextBlock { Text = Strings.Get("Compare/AllTables") } },
            },
        };
        back.Click += (_, _) => ViewModel.SelectedPlan = null;
        _planHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _planHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        _planHeader.Children.Add(back);
        Grid.SetColumn(_planTitle, 1);
        _planHeader.Children.Add(_planTitle);
        return _planHeader;
    }

    private Grid BuildPlanList()
    {
        var all = new Button { Content = Strings.Get("Compare/IncludeAll") };
        all.Click += (_, _) => ViewModel.SetIncluded(true);
        var none = new Button { Content = Strings.Get("Compare/IncludeNone") };
        none.Click += (_, _) => ViewModel.SetIncluded(false);
        _selectButtons.Children.Add(all);
        _selectButtons.Children.Add(none);

        var toolbar = new Grid { ColumnSpacing = 12 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.Children.Add(_selectButtons);
        Grid.SetColumn(_unpaired, 1);
        toolbar.Children.Add(_unpaired);

        _planList.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _planList.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _planList.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _planList.Children.Add(toolbar);
        Grid.SetRow(_plansEmpty, 1);
        _planList.Children.Add(_plansEmpty);
        Grid.SetRow(_plans, 2);
        _planList.Children.Add(_plans);
        AutomationProperties.SetName(_plans, Strings.Get("Compare/TablesListName"));
        return _planList;
    }

    private void RebuildPlanList()
    {
        DetachPlanRows();
        _plans.Items.Clear();
        foreach (var plan in ViewModel.TablePlans)
        {
            var row = new PlanRow(this, plan);
            row.UpdateScope(ViewModel.Scope);
            _planRows.Add(row);
            _plans.Items.Add(row.Root);
        }

        _plansEmpty.Visibility = ViewModel.TablePlans.Count == 0 && ViewModel.Target is not null ? Visibility.Visible : Visibility.Collapsed;
        _unpaired.Text = ViewModel.UnpairedTables is { } unpaired ? Strings.Format("Compare/UnpairedTables", unpaired) : string.Empty;
        UpdateVisibility();
    }

    private void DetachPlanRows()
    {
        foreach (var row in _planRows)
        {
            row.Detach();
        }

        _planRows.Clear();
    }

    private void ShowRows(CompareTablePlan plan)
    {
        if (plan.Outcome?.Result is not null)
        {
            ViewModel.SelectedPlan = plan;
        }
    }

    /// <summary>How a table is scoped, as its row says before it is compared.</summary>
    private static string DescribeScope(CompareTableScope scope)
    {
        var parts = new List<string>
        {
            scope.KeyColumns.Count > 0 ? Strings.Format("Compare/ScopeKey", string.Join(", ", scope.KeyColumns)) : Strings.Get("Compare/ScopePrimaryKey"),
        };
        if (scope.ExcludedColumns.Count > 0)
        {
            parts.Add(Strings.Plural("Compare/ScopeLeftOut", scope.ExcludedColumns.Count));
        }

        if (!scope.SourceBrowseFilter.IsEmpty || !scope.TargetBrowseFilter.IsEmpty)
        {
            parts.Add(Strings.Get("Compare/ScopeFiltered"));
        }

        if (scope.RowLimit is { } limit)
        {
            parts.Add(Strings.Format("Compare/ScopeFirstRows", limit));
        }

        return string.Join(" · ", parts);
    }

    private static string Describe(CompareTablePlan plan)
    {
        if (plan.IsComparing)
        {
            return Strings.Get("Compare/TableComparing");
        }

        if (plan.Outcome is not { } outcome)
        {
            return Strings.Get("Compare/NotCompared") + " · " + DescribeScope(plan.Scope);
        }

        if (outcome.Result is not { } result)
        {
            return outcome.Problem ?? string.Empty;
        }

        var text = result.DifferenceCount == 0
            ? Strings.Plural("Compare/TableSame", result.IdenticalCount)
            : Strings.Format("Compare/TableCounts", result.OnlyInSourceCount, result.ChangedCount, result.OnlyInTargetCount, result.IdenticalCount);
        if (plan.Excluded.Count > 0)
        {
            text += " · " + Strings.Plural("Compare/RowsSkipped", plan.Excluded.Count);
        }

        if (result.StoppedAtRowLimit)
        {
            text += " · " + Strings.Get("Compare/StoppedAtRowLimit");
        }

        if (result.IsTruncated)
        {
            text += " · " + Strings.Get("Compare/TooManyToSync");
        }

        return text;
    }

    /// <summary>The per-table scope editor: the key, the columns left out, each side's filter and the row limit.</summary>
    private void EditScope(CompareTablePlan plan, FrameworkElement anchor)
    {
        var scope = plan.Scope;
        var keys = new TextBox { Header = Strings.Get("Compare/KeyColumns"), PlaceholderText = Strings.Get("Compare/KeyColumnsPlaceholder"), Text = string.Join(", ", scope.KeyColumns) };
        var leaveOut = new TextBox { Header = Strings.Get("Compare/LeaveOutColumns"), PlaceholderText = "updated_at, version", Text = string.Join(", ", scope.ExcludedColumns) };
        var sourceFilter = new TextBox { Header = Strings.Get("Compare/SourceWhere"), PlaceholderText = "status = 'active'", Text = scope.SourceFilter ?? string.Empty };
        var same = new CheckBox { Content = Strings.Get("Compare/SameFilterForTarget"), IsChecked = scope.UsesSameFilterForTarget };
        var targetFilter = new TextBox { Header = Strings.Get("Compare/TargetWhere"), PlaceholderText = "status = 'active'", Text = scope.TargetFilter ?? string.Empty, IsEnabled = !scope.UsesSameFilterForTarget };
        same.Click += (_, _) => targetFilter.IsEnabled = same.IsChecked != true;
        var limit = new NumberBox { Header = Strings.Get("Compare/RowLimit"), PlaceholderText = Strings.Get("Compare/RowLimitPlaceholder"), Minimum = 1, Value = scope.RowLimit is { } rows ? rows : double.NaN };
        var apply = new Button { Content = Strings.Get("Common/Apply"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
        var reset = new Button { Content = Strings.Get("Common/Default") };
        var panel = new StackPanel { Spacing = 10, Width = 340 };
        panel.Children.Add(new TextBlock { Text = plan.DisplayName, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(keys);
        panel.Children.Add(leaveOut);
        panel.Children.Add(sourceFilter);
        panel.Children.Add(same);
        panel.Children.Add(targetFilter);
        panel.Children.Add(limit);
        panel.Children.Add(new TextBlock { Text = Strings.Get("Compare/ScopeNote"), TextWrapping = TextWrapping.Wrap, Opacity = 0.7 });
        panel.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Children = { reset, apply } });

        var flyout = new Flyout { Content = panel };
        apply.Click += (_, _) =>
        {
            var next = new CompareTableScope
            {
                KeyColumns = Split(keys.Text),
                ExcludedColumns = Split(leaveOut.Text),
                SourceFilter = string.IsNullOrWhiteSpace(sourceFilter.Text) ? null : sourceFilter.Text.Trim(),
                TargetFilter = same.IsChecked == true ? null : targetFilter.Text.Trim(),
                RowLimit = double.IsNaN(limit.Value) || limit.Value < 1 ? null : (long)limit.Value,
            };
            if (!SameScope(next, plan.Scope))
            {
                plan.Scope = next;
            }

            flyout.Hide();
        };
        reset.Click += (_, _) =>
        {
            if (!plan.Scope.IsDefault)
            {
                plan.Scope = CompareTableScope.Default;
            }

            flyout.Hide();
        };
        flyout.ShowAt(anchor);

        static string[] Split(string text) => text.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
    }

    // Records compare their lists by reference, so an unchanged scope typed back in would still look new.
    private static bool SameScope(CompareTableScope left, CompareTableScope right) =>
        left.KeyColumns.SequenceEqual(right.KeyColumns, StringComparer.OrdinalIgnoreCase)
        && left.ExcludedColumns.SequenceEqual(right.ExcludedColumns, StringComparer.OrdinalIgnoreCase)
        && string.Equals(left.SourceFilter, right.SourceFilter, StringComparison.Ordinal)
        && string.Equals(left.TargetFilter, right.TargetFilter, StringComparison.Ordinal)
        && left.RowLimit == right.RowLimit;

    /// <summary>One table pair in the list, kept in step with its plan as the run fills it in.</summary>
    private sealed class PlanRow
    {
        private readonly CompareTabView _view;
        private readonly CompareTablePlan _plan;
        private readonly CheckBox _include = new() { MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        private readonly TextBlock _detail = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
        private readonly ProgressRing _ring = new() { Width = 14, Height = 14, IsActive = false, Visibility = Visibility.Collapsed };
        private readonly Button _rows = new() { Content = Strings.Get("Compare/ShowRows") };

        public PlanRow(CompareTabView view, CompareTablePlan plan)
        {
            _view = view;
            _plan = plan;
            AutomationProperties.SetName(_include, Strings.Format("Compare/IncludeTable", plan.DisplayName));
            _include.Click += (_, _) => _plan.IsIncluded = _include.IsChecked == true;
            var scope = new Button { Content = Strings.Get("Compare/EditScope") };
            scope.Click += (_, _) => _view.EditScope(_plan, scope);
            _rows.Click += (_, _) => _view.ShowRows(_plan);

            var name = new TextBlock { Text = plan.DisplayName, Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"], TextTrimming = TextTrimming.CharacterEllipsis };
            // A grid rather than a horizontal stack, which would measure the detail at infinite width and never wrap it.
            var line = new Grid { ColumnSpacing = 6 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.Children.Add(_ring);
            Grid.SetColumn(_detail, 1);
            line.Children.Add(_detail);
            var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center, Children = { name, line } };
            Root = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 4, 0, 4) };
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Root.Children.Add(_include);
            Grid.SetColumn(texts, 1);
            Root.Children.Add(texts);
            Grid.SetColumn(scope, 2);
            Root.Children.Add(scope);
            Grid.SetColumn(_rows, 3);
            Root.Children.Add(_rows);
            Root.DoubleTapped += (_, _) => _view.ShowRows(_plan);

            plan.PropertyChanged += OnPlanChanged;
            Update();
        }

        public Grid Root { get; }

        public void Detach() => _plan.PropertyChanged -= OnPlanChanged;

        /// <summary>Under whole schema every table takes part, so the tick shows that and cannot be cleared.</summary>
        public void UpdateScope(DataCompareScope scope)
        {
            _include.IsEnabled = scope == DataCompareScope.ChosenTables;
            _include.IsChecked = scope == DataCompareScope.WholeSchema || _plan.IsIncluded;
        }

        private void OnPlanChanged(object? sender, PropertyChangedEventArgs e) => Update();

        /// <summary>Redraws the row, as after rows were skipped in its drill-in, which the plan does not announce.</summary>
        public void Update()
        {
            _include.IsChecked = _view.ViewModel.Scope == DataCompareScope.WholeSchema || _plan.IsIncluded;
            _ring.IsActive = _plan.IsComparing;
            _ring.Visibility = _plan.IsComparing ? Visibility.Visible : Visibility.Collapsed;
            _detail.Text = Describe(_plan);
            _rows.IsEnabled = _plan.Outcome?.Result is not null;
            if (_plan.Outcome is { State: not TableCompareState.Compared })
            {
                _detail.Foreground = ThemeResources.Brush(_detail, "SystemFillColorCriticalBrush");
                _detail.Opacity = 1;
            }
            else
            {
                _detail.ClearValue(TextBlock.ForegroundProperty);
                _detail.Opacity = 0.75;
            }
        }
    }
}
