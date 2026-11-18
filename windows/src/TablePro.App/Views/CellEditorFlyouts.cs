using System.Globalization;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using TablePro.App.Model;
using TablePro.App.Services;
using TablePro.DataGrid;
using TablePro.Interop;

namespace TablePro.App.Views;

// IsCurrent is false once the page or the focused cell has changed under the flyout.
internal sealed record CellEditRequest(
    DataGridView Grid,
    EditColumn Column,
    string Text,
    Func<bool> IsCurrent,
    Action<string> Commit);

// Built for each use: a flyout keeps the window it first opened in (microsoft/microsoft-ui-xaml#10207).
internal static class CellEditorFlyouts
{
    // A WinRT date starts in 1601 and the calendar lays out whole weeks around a date, so it stays well inside that.
    private const int FirstCalendarYear = 1800;
    private const int LastCalendarYear = 9000;

    public static void ShowChoice(CellEditRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var menu = new MenuFlyout();
        var labels = request.Column.Labels;
        for (var index = 0; index < labels.Count; index++)
        {
            var label = labels[index];
            var item = new RadioMenuFlyoutItem
            {
                // An empty label has no text of its own to show.
                Text = label.Length == 0 ? Strings.Get("GridMenuEmpty") : label,
                GroupName = "CellChoice",
                IsChecked = string.Equals(label, request.Text, StringComparison.Ordinal),
            };
            AutomationProperties.SetAutomationId(item, ChoiceId(index));
            item.Click += (_, _) => Commit(request, label);
            menu.Items.Add(item);
        }

        AddEditAsText(menu, request);
        ShowMenu(menu, request.Grid);
    }

    public static void ShowChoices(CellEditRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var menu = new MenuFlyout();
        var labels = request.Column.Labels;
        var members = CellEditors.Members(request.Text, labels);
        for (var index = 0; index < labels.Count; index++)
        {
            var label = labels[index];
            var item = new ToggleMenuFlyoutItem { Text = label, IsChecked = members.Contains(label) };
            AutomationProperties.SetAutomationId(item, ChoiceId(index));
            item.Click += (_, _) => Commit(request, CellEditors.ToggledMember(request.Text, labels, label));
            menu.Items.Add(item);
        }

        AddEditAsText(menu, request);
        ShowMenu(menu, request.Grid);
    }

    // Picking a day writes it; the value's own day, already selected, changes nothing.
    public static void ShowDate(CellEditRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var value = CellEditors.DateOf(request.Text);
        var calendar = Calendar(request.Column.Name, value);
        var flyout = new Flyout();
        calendar.SelectedDatesChanged += (_, args) =>
        {
            if (args.AddedDates.Count == 0)
            {
                return;
            }

            var picked = Day(args.AddedDates[0]);
            if (picked != value)
            {
                flyout.Hide();
                Commit(request, CellEditors.WithDate(request.Text, picked));
            }
        };
        flyout.Content = Stacked(calendar, Buttons(EditAsTextButton(flyout, request)));
        flyout.Opened += (_, _) => calendar.Focus(FocusState.Programmatic);
        ShowFlyout(flyout, request.Grid);
    }

    public static void ShowTime(CellEditRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var picker = TimeOfDay(request.Column.Name, CellEditors.TimeOf(request.Text));
        var flyout = new Flyout();
        var set = SetButton(() =>
        {
            if (picker.SelectedTime is { } time)
            {
                flyout.Hide();
                var today = DateOnly.FromDateTime(DateTime.Now);
                Commit(request, CellEditors.WithTime(request.Text, time.Hours, time.Minutes, LocalOffset(request, today, time)));
            }
        });
        flyout.Content = Stacked(picker, Buttons(EditAsTextButton(flyout, request), set));
        flyout.Opened += (_, _) => picker.Focus(FocusState.Programmatic);
        ShowFlyout(flyout, request.Grid);
    }

    // A value with no date or time to show opens on today and now, so Set always has both to write.
    public static void ShowTimestamp(CellEditRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var today = DateOnly.FromDateTime(DateTime.Now);
        var calendar = Calendar(request.Column.Name, CellEditors.DateOf(request.Text) ?? today);
        var picker = TimeOfDay(request.Column.Name, CellEditors.TimeOf(request.Text));
        var flyout = new Flyout();
        var set = SetButton(() =>
        {
            if (calendar.SelectedDates.Count > 0 && picker.SelectedTime is { } time)
            {
                var day = Day(calendar.SelectedDates[0]);
                flyout.Hide();
                Commit(request, CellEditors.WithDateAndTime(request.Text, day, time.Hours, time.Minutes, LocalOffset(request, day, time)));
            }
        });
        set.IsEnabled = calendar.SelectedDates.Count > 0;
        calendar.SelectedDatesChanged += (_, _) => set.IsEnabled = calendar.SelectedDates.Count > 0;
        flyout.Content = Stacked(calendar, picker, Buttons(EditAsTextButton(flyout, request), set));
        flyout.Opened += (_, _) => calendar.Focus(FocusState.Programmatic);
        ShowFlyout(flyout, request.Grid);
    }

    private static void Commit(CellEditRequest request, string text)
    {
        if (request.IsCurrent())
        {
            request.Commit(text);
        }
    }

    // A new value with an offset takes this machine's on the day and hour picked; a skipped or repeated hour, standard.
    private static TimeSpan? LocalOffset(CellEditRequest request, DateOnly day, TimeSpan time) =>
        request.Column.NeedsOffset
            ? TimeZoneInfo.Local.GetUtcOffset(
                day.ToDateTime(new TimeOnly(time.Hours, time.Minutes), DateTimeKind.Local))
            : null;

    private static string ChoiceId(int index) => "CellChoice" + index.ToString(CultureInfo.InvariantCulture);

    private static CalendarView Calendar(string column, DateOnly? value)
    {
        var calendar = new CalendarView { SelectionMode = CalendarViewSelectionMode.Single };
        AutomationProperties.SetAutomationId(calendar, "CellDatePicker");
        AutomationProperties.SetName(calendar, Strings.Format("CellDateName", column));
        if (value is { Year: >= FirstCalendarYear and <= LastCalendarYear } date)
        {
            var shown = Noon(date);
            // The calendar spans a century either side of today until told otherwise.
            if (shown < calendar.MinDate)
            {
                calendar.MinDate = Noon(new DateOnly(date.Year, 1, 1));
            }

            if (shown > calendar.MaxDate)
            {
                calendar.MaxDate = Noon(new DateOnly(date.Year, 12, 31));
            }

            calendar.SelectedDates.Add(shown);
            calendar.SetDisplayDate(shown);
        }

        return calendar;
    }

    // Noon, so a clock change at midnight cannot move the day the calendar shows.
    private static DateTimeOffset Noon(DateOnly date) => new(date.ToDateTime(new TimeOnly(12, 0)));

    // The calendar works in local time.
    private static DateOnly Day(DateTimeOffset date) => DateOnly.FromDateTime(date.ToLocalTime().DateTime);

    private static TimePicker TimeOfDay(string column, TimeOnly? value)
    {
        var time = value ?? TimeOnly.FromDateTime(DateTime.Now);
        var picker = new TimePicker { SelectedTime = new TimeSpan(time.Hour, time.Minute, 0) };
        AutomationProperties.SetAutomationId(picker, "CellTimePicker");
        AutomationProperties.SetName(picker, Strings.Format("CellTimeName", column));
        return picker;
    }

    private static StackPanel Stacked(params UIElement[] children)
    {
        var panel = new StackPanel { Spacing = 12 };
        foreach (var child in children)
        {
            panel.Children.Add(child);
        }

        return panel;
    }

    private static StackPanel Buttons(params Button[] buttons)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        foreach (var button in buttons)
        {
            row.Children.Add(button);
        }

        return row;
    }

    private static Button SetButton(Action set)
    {
        var button = new Button
        {
            Content = Strings.Get("CellSetValue"),
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        AutomationProperties.SetAutomationId(button, "CellSetValue");
        button.Click += (_, _) => set();
        return button;
    }

    private static Button EditAsTextButton(Flyout flyout, CellEditRequest request)
    {
        var button = new Button { Content = Strings.Get("CellEditAsText") };
        AutomationProperties.SetAutomationId(button, "CellEditAsText");
        var editAsText = EditAsTextOnClose(flyout, request);
        button.Click += (_, _) => editAsText();
        return button;
    }

    private static void AddEditAsText(MenuFlyout menu, CellEditRequest request)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get("CellEditAsText") };
        AutomationProperties.SetAutomationId(item, "CellEditAsText");
        var editAsText = EditAsTextOnClose(menu, request);
        item.Click += (_, _) => editAsText();
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(item);
    }

    // Opened before the flyout gives focus back to the grid, the TextBox would lose focus at once and close.
    private static Action EditAsTextOnClose(FlyoutBase flyout, CellEditRequest request)
    {
        var asked = false;
        var queued = false;
        void Queue()
        {
            if (queued)
            {
                return;
            }

            queued = true;
            request.Grid.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                if (request.IsCurrent())
                {
                    request.Grid.BeginTextEdit();
                }
            });
        }

        flyout.Closed += (_, _) =>
        {
            if (asked)
            {
                Queue();
            }
        };
        return () =>
        {
            asked = true;
            if (flyout.IsOpen)
            {
                flyout.Hide();
            }
            else
            {
                Queue();
            }
        };
    }

    // At the cell, as a menu opened from the keyboard goes: under it, left edges aligned.
    private static void ShowMenu(MenuFlyout menu, DataGridView grid)
    {
        grid.ScrollIntoView(grid.FocusedRow, grid.FocusedColumn);
        var at = grid.FocusedCellMenuPoint() is { } point ? new FlyoutShowOptions { Position = point } : null;
        GridMenus.Show(menu, grid, at);
    }

    private static void ShowFlyout(Flyout flyout, DataGridView grid)
    {
        grid.ScrollIntoView(grid.FocusedRow, grid.FocusedColumn);
        var options = new FlyoutShowOptions { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        if (grid.FocusedCellMenuPoint() is { } point)
        {
            options.Position = point;
        }

        flyout.ShowAt(grid, options);
    }
}
