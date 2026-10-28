using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;
using TablePro.App.Controls.DataGrid;
using TablePro.App.Services;
using TablePro.Core.Connections;
using TablePro.Core.Debugging;
using TablePro.Core.Drivers;

namespace TablePro.App.ViewModels;

/// <summary>One line of the routine's source, with its breakpoint and whether the run is stopped on it.</summary>
public sealed partial class DebugSourceLine(int number, string text) : ObservableObject
{
    public int Number { get; } = number;

    public string Text { get; } = text;

    [ObservableProperty]
    public partial bool HasBreakpoint { get; set; }

    [ObservableProperty]
    public partial bool IsCurrent { get; set; }
}

public sealed record DebugFrameItem(int Level, string Title, string? Detail);

public sealed record DebugVariableItem(string Name, string Kind, string Type, string Value, bool IsNull);

/// <summary>
/// The Debug tab: a routine stepped through with breakpoints, its call stack, the variables of the chosen frame and what
/// it printed. The run itself is <see cref="RoutineDebugController"/>; this mirrors its state for binding.
/// </summary>
public sealed partial class DebuggerTabViewModel : TabViewModel
{
    // Closing the tab stops the run; the controller's own limit already caps how long that takes.
    private static readonly TimeSpan CloseWait = TimeSpan.FromSeconds(6);

    private readonly WorkspaceContext _context;
    private readonly IRoutineDebugger _debugger;
    private readonly DispatcherQueue _dispatcher;
    private RoutineDebugController? _controller;
    private string? _shownUnit;
    private string? _shownSource;
    private IReadOnlyList<DebugFrame>? _shownFrames;
    private IReadOnlyList<DebugVariable>? _shownVariables;
    private int _shownOutput;
    private string? _shownLastLine;
    private bool _started;

    public DebuggerTabViewModel(WorkspaceContext context, IRoutineDebugger debugger, RoutineDebugTarget target)
    {
        _context = context;
        _debugger = debugger;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
        Target = target;
        Title = "Debug " + target.Name.Name;
        Subtitle = target.Name.Schema ?? context.Session.Profile.Name;
        StatusText = "Preparing…";
        ContinueCommand = new RelayCommand(() => Perform(DebugCommand.Continue), () => CanPerform(DebugCommand.Continue));
        StepOverCommand = new RelayCommand(() => Perform(DebugCommand.StepOver), () => CanPerform(DebugCommand.StepOver));
        StepIntoCommand = new RelayCommand(() => Perform(DebugCommand.StepInto), () => CanPerform(DebugCommand.StepInto));
        StepOutCommand = new RelayCommand(() => Perform(DebugCommand.StepOut), () => CanPerform(DebugCommand.StepOut));
        StopCommand = new RelayCommand(() => _controller?.Stop(), () => _controller?.CanStop ?? false);
        ToggleBreakpointCommand = new RelayCommand(() => _controller?.ToggleBreakpointAtCursor(), () => _controller?.CanToggleBreakpoint ?? false);
        RemoveAllBreakpointsCommand = new RelayCommand(() => _controller?.RemoveAllBreakpoints(), () => _controller?.CanRemoveAllBreakpoints ?? false);
    }

    /// <summary>The run has nothing to show, because the start was cancelled or the preparation declined; the tab can close.</summary>
    public event EventHandler? CloseRequested;

    public override string Glyph => "";

    public RoutineDebugTarget Target { get; }

    public WorkspaceContext Context => _context;

    public ObservableCollection<DebugSourceLine> Lines { get; } = [];

    public ObservableCollection<DebugFrameItem> Frames { get; } = [];

    public ObservableCollection<DebugVariableItem> Variables { get; } = [];

    public IRelayCommand ContinueCommand { get; }

    public IRelayCommand StepOverCommand { get; }

    public IRelayCommand StepIntoCommand { get; }

    public IRelayCommand StepOutCommand { get; }

    public IRelayCommand StopCommand { get; }

    public IRelayCommand ToggleBreakpointCommand { get; }

    public IRelayCommand RemoveAllBreakpointsCommand { get; }

    /// <summary>Why the run could not start or what went wrong reading a pause, shown above the source.</summary>
    [ObservableProperty]
    public partial string? Message { get; set; }

    [ObservableProperty]
    public partial string UnitName { get; set; } = string.Empty;

    [ObservableProperty]
    public partial int? ExecutionLine { get; set; }

    [ObservableProperty]
    public partial int? SelectedFrameLevel { get; set; }

    [ObservableProperty]
    public partial string OutputText { get; set; } = string.Empty;

    [ObservableProperty]
    public partial IGridSource? Result { get; set; }

    [ObservableProperty]
    public partial bool IsWorking { get; set; } = true;

    [ObservableProperty]
    public partial bool HasEnded { get; set; }

    public bool SupportsStepOut => _controller?.SupportedCommands.Contains(DebugCommand.StepOut) ?? true;

    /// <summary>
    /// Reads the plan, asks for the entry point and arguments, and starts the run. A routine the engine refuses, or a
    /// Safe Mode that blocks the writes it may make, ends here with the reason in <see cref="Message"/>.
    /// </summary>
    public async Task BeginAsync(
        Func<RoutineDebugPlan, Task<RoutineDebugStartChoice?>> choose,
        Func<RoutineDebugPreparation, CancellationToken, Task<bool>> confirmPreparation)
    {
        if (_started)
        {
            return;
        }

        _started = true;
        RoutineDebugPlan plan;
        try
        {
            plan = await _debugger.PrepareDebugAsync(Target, CancellationToken.None);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            Fail(RoutineDebugController.MessageOf(ex));
            return;
        }

        if (plan.MayWrite && _context.Session.Profile.SafeMode.BlocksAllWrites())
        {
            Fail("Safe Mode blocks writes on this connection, and the routine may change data, so it can't be debugged here.");
            return;
        }

        if (await choose(plan) is not { } choice)
        {
            IsWorking = false;
            CloseRequested?.Invoke(this, EventArgs.Empty);
            return;
        }

        var controller = new RoutineDebugController(_debugger, plan, choice, confirmPreparation);
        controller.Changed += OnControllerChanged;
        controller.Declined += (_, _) => CloseRequested?.Invoke(this, EventArgs.Empty);
        _controller = controller;
        UnitName = choice.EntryPoint.DisplayName;
        controller.Start();
        Refresh();
    }

    public void ToggleBreakpoint(int line) => _controller?.ToggleBreakpoint(line);

    public void SelectFrame(int level) => _controller?.SelectFrame(level);

    public void SetCursorLine(int? line)
    {
        if (_controller is { } controller)
        {
            controller.CursorLine = line;
            ToggleBreakpointCommand.NotifyCanExecuteChanged();
        }
    }

    public override async ValueTask DisposeAsync()
    {
        if (_controller is { } controller)
        {
            controller.Stop();
            await Task.WhenAny(controller.WaitUntilEndedAsync(), Task.Delay(CloseWait));
            controller.Changed -= OnControllerChanged;
            controller.Dispose();
        }

        await base.DisposeAsync();
    }

    private bool CanPerform(DebugCommand command) => _controller?.CanPerform(command) ?? false;

    private void Perform(DebugCommand command) => _controller?.Perform(command);

    private void Fail(string message)
    {
        Message = message;
        StatusText = "Can't debug";
        IsWorking = false;
        HasEnded = true;
    }

    // The controller raises on the thread that drives it, the UI thread; a driver callback that slipped off it is moved back.
    private void OnControllerChanged(object? sender, EventArgs e)
    {
        if (_dispatcher.HasThreadAccess)
        {
            Refresh();
        }
        else
        {
            _dispatcher.TryEnqueue(Refresh);
        }
    }

    private void Refresh()
    {
        if (_controller is not { } c)
        {
            return;
        }

        StatusText = c.StatusText;
        IsWorking = c.State is DebugRunState.Preparing or DebugRunState.Starting or DebugRunState.Running || (c.IsStopping && !c.HasEnded);
        HasEnded = c.HasEnded;
        Message = c.State == DebugRunState.Failed ? c.Message : c.InspectionError;
        if (c.DisplayedUnit is { } unit)
        {
            UnitName = unit.DisplayName;
        }

        RefreshSource(c);
        RefreshFrames(c);
        RefreshVariables(c);
        RefreshOutput(c);
        if (c.State == DebugRunState.Finished && c.Result is { } result && Result is null)
        {
            Result = new ResultGridSource(result);
        }

        OnPropertyChanged(nameof(SupportsStepOut));
        foreach (var command in new[] { ContinueCommand, StepOverCommand, StepIntoCommand, StepOutCommand, StopCommand, ToggleBreakpointCommand, RemoveAllBreakpointsCommand })
        {
            command.NotifyCanExecuteChanged();
        }
    }

    private void RefreshSource(RoutineDebugController c)
    {
        var unit = c.DisplayedUnit?.Identity;
        var source = c.DisplayedSource;
        if (unit != _shownUnit || !ReferenceEquals(source, _shownSource))
        {
            _shownUnit = unit;
            _shownSource = source;
            Lines.Clear();
            var number = 1;
            foreach (var text in DebugSourceText.Lines(source))
            {
                Lines.Add(new DebugSourceLine(number++, text));
            }
        }

        var breakpoints = c.DisplayedBreakpointLines;
        var current = c.ExecutionLine;
        foreach (var line in Lines)
        {
            line.HasBreakpoint = breakpoints.Contains(line.Number);
            line.IsCurrent = line.Number == current;
        }

        ExecutionLine = current;
    }

    private void RefreshFrames(RoutineDebugController c)
    {
        if (!ReferenceEquals(c.Frames, _shownFrames))
        {
            _shownFrames = c.Frames;
            Frames.Clear();
            foreach (var frame in c.Frames)
            {
                var title = frame.Location is { } location ? $"{location.Unit.DisplayName}  line {location.Line}" : $"Frame {frame.Level}";
                Frames.Add(new DebugFrameItem(frame.Level, title, frame.Description));
            }
        }

        SelectedFrameLevel = c.StackIsCurrent ? c.SelectedFrameLevel : null;
    }

    private void RefreshVariables(RoutineDebugController c)
    {
        if (ReferenceEquals(c.Variables, _shownVariables))
        {
            return;
        }

        _shownVariables = c.Variables;
        Variables.Clear();
        foreach (var variable in c.Variables)
        {
            var kind = variable.Kind switch
            {
                DebugVariableKind.Argument => "Argument",
                DebugVariableKind.Package => "Package",
                _ => variable.IsConstant ? "Constant" : "Local",
            };
            Variables.Add(new DebugVariableItem(variable.Name, kind, variable.TypeName ?? string.Empty, variable.Value ?? "NULL", variable.Value is null));
        }
    }

    private void RefreshOutput(RoutineDebugController c)
    {
        // At the line limit the count stops growing while old lines drop, so the last line tells a change too.
        var last = c.OutputLines.Count > 0 ? c.OutputLines[^1] : null;
        if (c.OutputLines.Count != _shownOutput || !ReferenceEquals(last, _shownLastLine))
        {
            _shownOutput = c.OutputLines.Count;
            _shownLastLine = last;
            OutputText = string.Join(Environment.NewLine, c.OutputLines);
        }
    }
}
