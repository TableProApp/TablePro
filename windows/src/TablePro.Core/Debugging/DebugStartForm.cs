using TablePro.Core.Drivers;

namespace TablePro.Core.Debugging;

/// <summary>What the start dialog edits: which entry point runs and what each of its parameters is given.</summary>
public sealed class DebugStartForm
{
    public DebugStartForm(RoutineDebugPlan plan)
    {
        Plan = plan;
        Arguments = InputsFor(EntryPoint);
    }

    public RoutineDebugPlan Plan { get; }

    public int EntryPointIndex { get; private set; }

    public DebugEntryPoint? EntryPoint => EntryPointIndex < Plan.EntryPoints.Count ? Plan.EntryPoints[EntryPointIndex] : null;

    public IReadOnlyList<DebugArgumentInput> Arguments { get; private set; }

    /// <summary>Picks another entry point; its parameters start over, each defaulted one at its default.</summary>
    public bool SelectEntryPoint(int index)
    {
        if (index < 0 || index >= Plan.EntryPoints.Count || index == EntryPointIndex)
        {
            return false;
        }

        EntryPointIndex = index;
        Arguments = InputsFor(EntryPoint);
        return true;
    }

    /// <summary>The choice to start with, or null when the plan offers no entry point. Output parameters take no value.</summary>
    public RoutineDebugStartChoice? ToChoice() =>
        EntryPoint is { } entryPoint
            ? new RoutineDebugStartChoice(entryPoint, [.. Arguments.Where(a => a.TakesValue).Select(a => new DebugArgument(a.Parameter.Name, a.Value))])
            : null;

    private static DebugArgumentInput[] InputsFor(DebugEntryPoint? entryPoint) =>
        entryPoint is null ? [] : [.. entryPoint.Parameters.Select(p => new DebugArgumentInput(p))];
}

/// <summary>One parameter's value in the start dialog: typed text, NULL, or the routine's default. NULL and Default exclude each other.</summary>
public sealed class DebugArgumentInput
{
    private bool _isNull;
    private bool _usesDefault;

    public DebugArgumentInput(DebugParameter parameter)
    {
        Parameter = parameter;
        _usesDefault = parameter.HasDefault && parameter.TakesValue;
    }

    public DebugParameter Parameter { get; }

    public string Text { get; set; } = string.Empty;

    public bool TakesValue => Parameter.TakesValue;

    public bool CanUseDefault => TakesValue && Parameter.HasDefault;

    public bool IsNull
    {
        get => _isNull;
        set
        {
            _isNull = value && TakesValue;
            if (_isNull)
            {
                _usesDefault = false;
            }
        }
    }

    public bool UsesDefault
    {
        get => _usesDefault;
        set
        {
            _usesDefault = value && CanUseDefault;
            if (_usesDefault)
            {
                _isNull = false;
            }
        }
    }

    public DebugArgumentValue Value => UsesDefault ? DebugArgumentValue.Default : IsNull ? DebugArgumentValue.Null : DebugArgumentValue.FromText(Text);
}
