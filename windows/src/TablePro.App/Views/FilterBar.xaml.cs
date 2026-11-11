using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// A table tab's WHERE as rule rows over TableFilterDraft: the draft is what is typed, the tab's Filter what is applied.
public sealed partial class FilterBar : UserControl
{
    private readonly TableTab _tab;
    private readonly List<RuleRow> _rows = [];
    private TableFilterDraft? _draft;
    private bool _busy;
    private bool _applying;

    internal FilterBar(TableTab tab)
    {
        InitializeComponent();
        _tab = tab;
    }

    // Hiding the bar would leave this focus nowhere.
    internal bool HasFocus
    {
        get
        {
            if (XamlRoot is null)
            {
                return false;
            }

            for (var element = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
                element is not null;
                element = VisualTreeHelper.GetParent(element))
            {
                if (ReferenceEquals(element, this))
                {
                    return true;
                }
            }

            return false;
        }
    }

    // While the tab reads or saves, a filter would not apply.
    internal void SetBusy(bool busy)
    {
        _busy = busy;
        UpdateCommands();
    }

    // The choices are read once and again after a refresh; rows typed over the old ones are kept over the new.
    internal async Task LoadAsync(bool focus)
    {
        if (_draft is null)
        {
            ShowLoading(true);
        }

        var choices = await _tab.LoadFilterChoicesAsync().ConfigureAwait(true);
        ShowLoading(false);
        // Null when the read failed, which ShowChoicesFailed says, or the tab closed.
        if (choices is null)
        {
            return;
        }

        if (_draft is null)
        {
            MessageBar.IsOpen = false;
            ShowDraft(Fresh(_tab.Filter, choices));
        }
        else if (!ReferenceEquals(_draft.Choices, choices))
        {
            Sync(_draft);
            MessageBar.IsOpen = false;
            ShowDraft(Rebase(_draft, choices));
        }

        if (focus)
        {
            FocusFirst();
        }
    }

    internal void ShowChoicesFailed(CoreError failure) => ShowMessage(Strings.Error(failure), retry: true);

    // An empty filter shows one row to fill in.
    private static TableFilterDraft Fresh(TableFilter? filter, FilterChoices choices)
    {
        var draft = TableFilterDraft.From(filter, choices);
        if (draft.IsEmpty)
        {
            draft.AddRule();
        }

        return draft;
    }

    // The rows as typed, over the columns a refresh read; a column the table no longer has is the core's to refuse.
    private static TableFilterDraft Rebase(TableFilterDraft old, FilterChoices choices)
    {
        var draft = new TableFilterDraft(choices) { MatchAny = old.MatchAny, RawSql = old.RawSql };
        foreach (var rule in old.Rules)
        {
            var copy = draft.AddRule();
            copy.Column = rule.Column;
            copy.Operator = rule.Operator;
            copy.Value = rule.Value;
            copy.SecondValue = rule.SecondValue;
        }

        return draft;
    }

    private static string OperatorText(FilterOperator op) => Strings.Get("FilterOp_" + Enum.GetName(op));

    // A control added in this pass takes focus only once it has loaded.
    private static void FocusWhenLoaded(Control control)
    {
        if (control.IsLoaded)
        {
            control.Focus(FocusState.Programmatic);
            return;
        }

        void OnLoaded(object sender, RoutedEventArgs e)
        {
            control.Loaded -= OnLoaded;
            control.Focus(FocusState.Programmatic);
        }

        control.Loaded += OnLoaded;
    }

    private void ShowDraft(TableFilterDraft draft)
    {
        _draft = draft;
        RawSqlRow.Visibility = draft.AcceptsRawSql ? Visibility.Visible : Visibility.Collapsed;
        RawSqlBox.Text = draft.RawSql;
        MatchBox.SelectedIndex = draft.MatchAny ? 1 : 0;
        Footer.Visibility = Visibility.Visible;
        ShowRules(draft);
    }

    // Built again on each add and remove, so each row's AutomationId and name number it as it now stands.
    private void ShowRules(TableFilterDraft draft)
    {
        _rows.Clear();
        RulesPanel.Children.Clear();
        for (var index = 0; index < draft.Rules.Count; index++)
        {
            var row = new RuleRow(this, draft, draft.Rules[index], index);
            _rows.Add(row);
            RulesPanel.Children.Add(row.Root);
        }

        UpdateMatch();
        UpdateCommands();
    }

    // TextChanged is raised asynchronously, so Enter or a click can come before the last text reached the draft.
    private void Sync(TableFilterDraft draft)
    {
        foreach (var row in _rows)
        {
            row.Sync();
        }

        draft.RawSql = RawSqlBox.Text;
    }

    private async Task ApplyAsync()
    {
        if (_draft is not { } draft || _busy || _applying)
        {
            return;
        }

        Sync(draft);
        if (!draft.TryBuild(out var filter, out var problem))
        {
            if (problem is not null)
            {
                ShowProblem(problem);
            }

            return;
        }

        MessageBar.IsOpen = false;
        var focused = FocusedRow();
        await RunFilterAsync(filter).ConfigureAwait(true);
        // A filter the core refused, or one held back to keep pending edits, stays as typed to be fixed or tried again.
        if (!ReferenceEquals(_tab.Filter, filter) || !ReferenceEquals(_draft, draft))
        {
            return;
        }

        ShowDraft(Fresh(filter, draft.Choices));
        if (focused is { } row && row < _rows.Count)
        {
            _rows[row].FocusValue();
        }
    }

    // With no filter applied, Clear only empties the rows.
    private async Task ClearAsync()
    {
        if (_draft is not { } draft || _busy || _applying)
        {
            return;
        }

        MessageBar.IsOpen = false;
        if (_tab.Filter is not null)
        {
            await RunFilterAsync(null).ConfigureAwait(true);
            // Held back to keep pending edits, or the read failed: the rows typed stay.
            if (_tab.Filter is not null)
            {
                return;
            }
        }

        if (ReferenceEquals(_draft, draft))
        {
            ShowDraft(Fresh(null, draft.Choices));
        }
    }

    private async Task RunFilterAsync(TableFilter? filter)
    {
        _applying = true;
        UpdateCommands();
        try
        {
            await _tab.ApplyFilterAsync(filter).ConfigureAwait(true);
        }
        finally
        {
            _applying = false;
            UpdateCommands();
        }
    }

    private void AddRule()
    {
        if (_draft is not { } draft)
        {
            return;
        }

        Sync(draft);
        draft.AddRule();
        ShowRules(draft);
        _rows[^1].FocusColumn();
    }

    private void RemoveRule(FilterDraftRule rule)
    {
        if (_draft is not { } draft)
        {
            return;
        }

        Sync(draft);
        var index = _rows.FindIndex(row => ReferenceEquals(row.Rule, rule));
        draft.RemoveRule(rule);
        // Add is on each row; without the raw SQL row's, one row stays so there is an Add to press.
        if (draft.Rules.Count == 0 && !draft.AcceptsRawSql)
        {
            draft.AddRule();
        }

        ShowRules(draft);
        if (_rows.Count > 0)
        {
            _rows[Math.Clamp(index, 0, _rows.Count - 1)].FocusColumn();
        }
        else
        {
            FocusWhenLoaded(RawSqlBox);
        }
    }

    private void FocusFirst()
    {
        if (_rows.Count > 0)
        {
            _rows[0].FocusValue();
        }
        else
        {
            FocusWhenLoaded(RawSqlBox);
        }
    }

    private int? FocusedRow()
    {
        if (XamlRoot is null || FocusManager.GetFocusedElement(XamlRoot) is not DependencyObject focused)
        {
            return null;
        }

        var index = _rows.FindIndex(row => row.Holds(focused));
        return index >= 0 ? index : null;
    }

    // The row's box takes focus, and the bar says why, since a focus move alone does not.
    private void ShowProblem(FilterProblem problem)
    {
        ShowMessage(
            Strings.Get(problem.Kind switch
            {
                FilterProblemKind.NoColumn => "FilterNoColumn",
                FilterProblemKind.NoValue => "FilterNoValue",
                _ => "FilterNoSecondValue",
            }),
            retry: false);
        if (problem.Row >= 0 && problem.Row < _rows.Count)
        {
            _rows[problem.Row].Focus(problem.Kind);
        }
    }

    // Narrator reads an InfoBar when it opens, not when its text changes.
    private void ShowMessage(string message, bool retry)
    {
        MessageBar.Message = message;
        RetryButton.Visibility = retry ? Visibility.Visible : Visibility.Collapsed;
        MessageBar.IsOpen = false;
        MessageBar.IsOpen = true;
    }

    private void ShowLoading(bool loading)
    {
        LoadingRing.IsActive = loading;
        LoadingRing.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateMatch() =>
        MatchBox.Visibility = _draft is { ShowsMatch: true } ? Visibility.Visible : Visibility.Collapsed;

    private void UpdateCommands()
    {
        var ready = _draft is not null && !_busy && !_applying;
        ApplyButton.IsEnabled = ready;
        ClearButton.IsEnabled = ready;
    }

    private async void OnApply(object sender, RoutedEventArgs e) => await ApplyAsync().ConfigureAwait(true);

    private async void OnClear(object sender, RoutedEventArgs e) => await ClearAsync().ConfigureAwait(true);

    private async void OnRetry(object sender, RoutedEventArgs e)
    {
        MessageBar.IsOpen = false;
        await LoadAsync(focus: true).ConfigureAwait(true);
    }

    private async void OnValueKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != VirtualKey.Enter)
        {
            return;
        }

        e.Handled = true;
        await ApplyAsync().ConfigureAwait(true);
    }

    private void OnAddFromRawSql(object sender, RoutedEventArgs e) => AddRule();

    private void OnRawSqlChanged(object sender, TextChangedEventArgs e)
    {
        if (_draft is { } draft)
        {
            draft.RawSql = RawSqlBox.Text;
            UpdateMatch();
        }
    }

    private void OnMatchChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_draft is { } draft && MatchBox.SelectedIndex >= 0)
        {
            draft.MatchAny = MatchBox.SelectedIndex == 1;
        }
    }

    // One rule's controls; the draft's rule holds what they show.
    private sealed class RuleRow
    {
        private static readonly GridLength[] Widths =
        [
            new(180),
            new(160),
            new(1, GridUnitType.Star),
            GridLength.Auto,
            new(1, GridUnitType.Star),
            GridLength.Auto,
            GridLength.Auto,
        ];

        private readonly TableFilterDraft _draft;
        private readonly IReadOnlyList<string> _columns;
        private readonly ComboBox _columnBox;
        private readonly ComboBox _operatorBox;
        private readonly TextBox _valueBox;
        private readonly TextBlock _andText;
        private readonly TextBox _secondBox;
        private IReadOnlyList<FilterOperator> _operators = [];

        public RuleRow(FilterBar bar, TableFilterDraft draft, FilterDraftRule rule, int index)
        {
            _draft = draft;
            _columns = draft.Columns;
            Rule = rule;
            var id = index.ToString(CultureInfo.InvariantCulture);
            var number = index + 1;
            _columnBox = Named(
                new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch },
                "FilterColumn" + id,
                Strings.Format("FilterColumnName", number));
            foreach (var column in _columns)
            {
                _columnBox.Items.Add(new ComboBoxItem { Content = column });
            }

            // None is selected for a column the table no longer lists, as from a restored filter.
            _columnBox.SelectedIndex = IndexOf(_columns, rule.Column);
            _operatorBox = Named(
                new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch },
                "FilterOperator" + id,
                Strings.Format("FilterOperatorName", number));
            _valueBox = Named(
                new TextBox { Text = rule.Value, IsSpellCheckEnabled = false },
                "FilterValue" + id,
                Strings.Format("FilterValueName", number));
            _andText = new TextBlock { Text = Strings.Get("FilterAnd"), VerticalAlignment = VerticalAlignment.Center };
            AutomationProperties.SetAutomationId(_andText, "FilterAnd" + id);
            _secondBox = Named(
                new TextBox
                {
                    Text = rule.SecondValue,
                    IsSpellCheckEnabled = false,
                    PlaceholderText = Strings.Get("FilterValuePlaceholder"),
                },
                "FilterSecondValue" + id,
                Strings.Format("FilterSecondValueName", number));
            var add = IconButton(Symbol.Add, "AddFilter" + id, Strings.Get("FilterAdd"), Strings.Get("FilterAdd"));
            var remove = IconButton(
                Symbol.Remove,
                "RemoveFilter" + id,
                Strings.Format("FilterRemoveName", number),
                Strings.Get("FilterRemove"));

            Root = new Grid { ColumnSpacing = 8 };
            foreach (var width in Widths)
            {
                Root.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            }

            Place(_columnBox, 0);
            Place(_operatorBox, 1);
            Place(_valueBox, 2);
            Place(_andText, 3);
            Place(_secondBox, 4);
            Place(add, 5);
            Place(remove, 6);
            FillOperators();
            UpdateShape();

            _columnBox.SelectionChanged += (_, _) => OnColumnChanged();
            _operatorBox.SelectionChanged += (_, _) => OnOperatorChanged();
            _valueBox.TextChanged += (_, _) => Rule.Value = _valueBox.Text;
            _secondBox.TextChanged += (_, _) => Rule.SecondValue = _secondBox.Text;
            _valueBox.KeyDown += bar.OnValueKeyDown;
            _secondBox.KeyDown += bar.OnValueKeyDown;
            add.Click += (_, _) => bar.AddRule();
            remove.Click += (_, _) => bar.RemoveRule(Rule);
        }

        public FilterDraftRule Rule { get; }

        public Grid Root { get; }

        public bool Holds(DependencyObject element) =>
            ReferenceEquals(element, _columnBox)
            || ReferenceEquals(element, _operatorBox)
            || ReferenceEquals(element, _valueBox)
            || ReferenceEquals(element, _secondBox);

        public void Sync()
        {
            Rule.Value = _valueBox.Text;
            Rule.SecondValue = _secondBox.Text;
        }

        public void Focus(FilterProblemKind kind) => FocusWhenLoaded(kind switch
        {
            FilterProblemKind.NoColumn => (Control)_columnBox,
            FilterProblemKind.NoSecondValue => _secondBox,
            _ => _valueBox,
        });

        public void FocusValue() =>
            FocusWhenLoaded(_valueBox.Visibility == Visibility.Visible ? (Control)_valueBox : _operatorBox);

        public void FocusColumn() => FocusWhenLoaded(_columnBox);

        private static T Named<T>(T element, string automationId, string name)
            where T : DependencyObject
        {
            AutomationProperties.SetAutomationId(element, automationId);
            AutomationProperties.SetName(element, name);
            return element;
        }

        private static Button IconButton(Symbol symbol, string automationId, string name, string tip)
        {
            var button = Named(new Button { Content = new SymbolIcon(symbol) }, automationId, name);
            ToolTipService.SetToolTip(button, tip);
            return button;
        }

        private static int IndexOf<T>(IReadOnlyList<T> items, T item)
        {
            for (var index = 0; index < items.Count; index++)
            {
                if (EqualityComparer<T>.Default.Equals(items[index], item))
                {
                    return index;
                }
            }

            return -1;
        }

        private void Place(FrameworkElement element, int column)
        {
            Grid.SetColumn(element, column);
            Root.Children.Add(element);
        }

        // An operator the column does not offer, as from a restored filter, stays listed so the row shows what applies.
        private void FillOperators()
        {
            var offered = _draft.OperatorsFor(Rule.Column);
            _operators = offered.Contains(Rule.Operator) ? offered : [.. offered, Rule.Operator];
            _operatorBox.Items.Clear();
            foreach (var op in _operators)
            {
                _operatorBox.Items.Add(new ComboBoxItem { Content = OperatorText(op) });
            }

            _operatorBox.SelectedIndex = IndexOf(_operators, Rule.Operator);
        }

        private void OnColumnChanged()
        {
            var index = _columnBox.SelectedIndex;
            if (index < 0 || index >= _columns.Count)
            {
                return;
            }

            _draft.SetColumn(Rule, _columns[index]);
            FillOperators();
            UpdateShape();
        }

        private void OnOperatorChanged()
        {
            var index = _operatorBox.SelectedIndex;
            if (index < 0 || index >= _operators.Count)
            {
                return;
            }

            Rule.Operator = _operators[index];
            UpdateShape();
        }

        // Between takes a second value after "and"; a list takes its items in one box; the NULL tests take none.
        private void UpdateShape()
        {
            var shape = Rule.Shape;
            var two = shape == FilterValueShape.Two;
            _valueBox.Visibility = shape == FilterValueShape.None ? Visibility.Collapsed : Visibility.Visible;
            Grid.SetColumnSpan(_valueBox, two ? 1 : 3);
            _valueBox.PlaceholderText =
                Strings.Get(shape == FilterValueShape.List ? "FilterListPlaceholder" : "FilterValuePlaceholder");
            _andText.Visibility = two ? Visibility.Visible : Visibility.Collapsed;
            _secondBox.Visibility = _andText.Visibility;
        }
    }
}
