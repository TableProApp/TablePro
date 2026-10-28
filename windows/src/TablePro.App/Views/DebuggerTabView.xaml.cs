using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Services;
using TablePro.App.ViewModels;
using TablePro.Core.Debugging;
using TablePro.Core.Drivers;
using Windows.System;

namespace TablePro.App.Views;

/// <summary>
/// The Debug tab: the call stack beside the routine's source, whose gutter holds the breakpoints and marks the paused
/// line, and under them the chosen frame's variables beside the routine's output. The keys are the Windows debuggers'
/// own, scoped to the tab so they never reach the editor's F5.
/// </summary>
public sealed partial class DebuggerTabView : UserControl
{
    private bool _syncingFrame;
    private bool _begun;

    public DebuggerTabView(DebuggerTabViewModel viewModel)
    {
        ViewModel = viewModel;
        InitializeComponent();
        AddAccelerator(VirtualKey.F5, VirtualKeyModifiers.None, viewModel.ContinueCommand);
        AddAccelerator(VirtualKey.F10, VirtualKeyModifiers.None, viewModel.StepOverCommand);
        AddAccelerator(VirtualKey.F11, VirtualKeyModifiers.None, viewModel.StepIntoCommand);
        AddAccelerator(VirtualKey.F11, VirtualKeyModifiers.Shift, viewModel.StepOutCommand);
        AddAccelerator(VirtualKey.F5, VirtualKeyModifiers.Shift, viewModel.StopCommand);
        AddAccelerator(VirtualKey.F9, VirtualKeyModifiers.None, viewModel.ToggleBreakpointCommand);
        AddAccelerator(VirtualKey.F9, VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift, viewModel.RemoveAllBreakpointsCommand);

        viewModel.CloseRequested += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        viewModel.PropertyChanged += (_, e) =>
        {
            switch (e.PropertyName)
            {
                case nameof(DebuggerTabViewModel.ExecutionLine):
                    RevealExecutionLine();
                    break;
                case nameof(DebuggerTabViewModel.SelectedFrameLevel):
                    SyncSelectedFrame();
                    break;
                case nameof(DebuggerTabViewModel.Result):
                    ShowResult();
                    break;
                case nameof(DebuggerTabViewModel.OutputText):
                    OutputBox.SelectionStart = OutputBox.Text.Length;
                    break;
            }
        };

        Loaded += async (_, _) =>
        {
            if (_begun)
            {
                return;
            }

            _begun = true;
            await ViewModel.BeginAsync(ChooseAsync, ConfirmPreparationAsync);
        };
    }

    /// <summary>The run was cancelled before it began, or its preparation declined, so the tab has nothing to show.</summary>
    public event EventHandler? CloseRequested;

    public DebuggerTabViewModel ViewModel { get; }

    private DialogService Dialogs => ViewModel.Context.Dialogs;

    private void AddAccelerator(VirtualKey key, VirtualKeyModifiers modifiers, CommunityToolkit.Mvvm.Input.IRelayCommand command)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = modifiers, ScopeOwner = this };
        accelerator.Invoked += (_, e) =>
        {
            if (command.CanExecute(null))
            {
                command.Execute(null);
            }

            // Handled either way: F10 would otherwise open the window's menu, and F5 reach a query tab's Run All.
            e.Handled = true;
        };
        Root.KeyboardAccelerators.Add(accelerator);
    }

    private void OnGutterTapped(object sender, TappedRoutedEventArgs e)
    {
        if ((sender as FrameworkElement)?.DataContext is DebugSourceLine line)
        {
            ViewModel.ToggleBreakpoint(line.Number);
            e.Handled = true;
        }
    }

    private void OnSourceLineSelected(object sender, SelectionChangedEventArgs e) =>
        ViewModel.SetCursorLine((SourceList.SelectedItem as DebugSourceLine)?.Number);

    private void OnFrameSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncingFrame && StackList.SelectedItem is DebugFrameItem frame)
        {
            ViewModel.SelectFrame(frame.Level);
        }
    }

    private void SyncSelectedFrame()
    {
        _syncingFrame = true;
        StackList.SelectedItem = ViewModel.Frames.FirstOrDefault(f => f.Level == ViewModel.SelectedFrameLevel);
        _syncingFrame = false;
    }

    private void RevealExecutionLine()
    {
        if (ViewModel.ExecutionLine is { } number && ViewModel.Lines.FirstOrDefault(l => l.Number == number) is { } line)
        {
            SourceList.ScrollIntoView(line, ScrollIntoViewAlignment.Default);
        }
    }

    private void ShowResult()
    {
        ResultGrid.Source = ViewModel.Result;
        ResultTab.Visibility = ViewModel.Result is null ? Visibility.Collapsed : Visibility.Visible;
        if (ViewModel.Result is not null)
        {
            OutputTabs.SelectedItem = ResultTab;
        }
    }

    private void OnOutputTabChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        var showsResult = sender.SelectedItem?.Tag as string == "Result";
        ResultGrid.Visibility = showsResult ? Visibility.Visible : Visibility.Collapsed;
        OutputBox.Visibility = showsResult ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>The start dialog: which entry point runs, and each parameter as text, NULL or its default.</summary>
    private async Task<RoutineDebugStartChoice?> ChooseAsync(RoutineDebugPlan plan)
    {
        var form = new DebugStartForm(plan);
        var panel = new StackPanel { Spacing = 12, MinWidth = 460 };
        var arguments = new StackPanel { Spacing = 8 };
        if (plan.EntryPoints.Count > 1)
        {
            var entryPoints = new ComboBox
            {
                Header = "Entry point",
                ItemsSource = plan.EntryPoints.Select(e => e.DisplayName).ToList(),
                SelectedIndex = 0,
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            entryPoints.SelectionChanged += (_, _) =>
            {
                if (form.SelectEntryPoint(entryPoints.SelectedIndex))
                {
                    BuildArguments(arguments, form);
                }
            };
            panel.Children.Add(entryPoints);
        }

        BuildArguments(arguments, form);
        panel.Children.Add(arguments);
        if (!string.IsNullOrEmpty(plan.Note))
        {
            panel.Children.Add(new TextBlock
            {
                Text = plan.Note,
                TextWrapping = TextWrapping.Wrap,
                Style = (Style)Application.Current.Resources["CaptionTextBlockStyle"],
                Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"],
            });
        }

        var dialog = Dialogs.Create("Debug " + plan.Target.DisplayName, new ScrollViewer { Content = panel, MaxHeight = 480 }, "Debug", "Cancel");
        return await Dialogs.ShowAsync(dialog) == ContentDialogResult.Primary ? form.ToChoice() : null;
    }

    private static void BuildArguments(StackPanel host, DebugStartForm form)
    {
        host.Children.Clear();
        if (form.Arguments.Count == 0)
        {
            host.Children.Add(new TextBlock { Text = "This routine takes no arguments.", Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["TextFillColorSecondaryBrush"] });
            return;
        }

        foreach (var input in form.Arguments)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            var value = new TextBox
            {
                Header = $"{input.Parameter.Name} ({input.Parameter.TypeName})",
                Text = input.Text,
                PlaceholderText = input.TakesValue ? "Value" : "Output",
            };
            var isNull = new CheckBox { Content = "NULL", IsChecked = input.IsNull, IsEnabled = input.TakesValue, MinWidth = 0, VerticalAlignment = VerticalAlignment.Bottom };
            var useDefault = new CheckBox { Content = "Default", IsChecked = input.UsesDefault, IsEnabled = input.CanUseDefault, MinWidth = 0, VerticalAlignment = VerticalAlignment.Bottom };

            void Sync()
            {
                isNull.IsChecked = input.IsNull;
                useDefault.IsChecked = input.UsesDefault;
                value.IsEnabled = input.TakesValue && !input.IsNull && !input.UsesDefault;
            }

            value.TextChanged += (_, _) => input.Text = value.Text;
            isNull.Click += (_, _) =>
            {
                input.IsNull = isNull.IsChecked == true;
                Sync();
            };
            useDefault.Click += (_, _) =>
            {
                input.UsesDefault = useDefault.IsChecked == true;
                Sync();
            };
            Sync();

            Grid.SetColumn(isNull, 1);
            Grid.SetColumn(useDefault, 2);
            row.Children.Add(value);
            row.Children.Add(isNull);
            row.Children.Add(useDefault);
            host.Children.Add(row);
        }
    }

    /// <summary>Asks before a preparation such as Oracle's compile for debug; a stop while it is up withdraws it.</summary>
    private async Task<bool> ConfirmPreparationAsync(RoutineDebugPreparation preparation, CancellationToken cancellationToken)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 560 };
        if (!string.IsNullOrEmpty(preparation.InformativeText))
        {
            body.Children.Add(new TextBlock { Text = preparation.InformativeText, TextWrapping = TextWrapping.Wrap });
        }

        body.Children.Add(DialogService.CodeBlock(string.Join(";\n", preparation.Statements), 160));
        var dialog = Dialogs.Create(preparation.Message, body, preparation.ActionTitle, "Cancel");
        await using var registration = cancellationToken.Register(() => DispatcherQueue.TryEnqueue(dialog.Hide));
        return await Dialogs.ShowAsync(dialog) == ContentDialogResult.Primary && !cancellationToken.IsCancellationRequested;
    }
}
