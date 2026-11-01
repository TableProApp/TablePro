using TablePro.Core.Localization;

namespace TablePro.Core.Shortcuts;

public enum ShortcutConflictKind
{
    None,

    /// <summary>The chord has no Ctrl, Alt or function key, and the command needs one.</summary>
    NeedsModifier,

    /// <summary>Windows owns the chord.</summary>
    SystemReserved,

    /// <summary>A built-in of the window, the editor or the grid answers to it; <see cref="ShortcutConflict.Name"/> says which.</summary>
    Reserved,

    /// <summary>Another customizable command has it; <see cref="ShortcutConflict.Command"/> says which, and the user may move it over.</summary>
    Command,
}

/// <summary>What recording a chord for a command would collide with.</summary>
public readonly record struct ShortcutConflict(ShortcutConflictKind Kind, string? Name = null, ShortcutCommand? Command = null)
{
    public static ShortcutConflict None => default;

    /// <summary>The chord cannot be assigned at all; only a <see cref="ShortcutConflictKind.Command"/> conflict can be resolved by reassigning.</summary>
    public bool IsBlocking => Kind is ShortcutConflictKind.NeedsModifier or ShortcutConflictKind.SystemReserved or ShortcutConflictKind.Reserved;

    /// <summary>A sentence for the settings page explaining the conflict.</summary>
    public string Describe(KeyChord chord) => Kind switch
    {
        ShortcutConflictKind.NeedsModifier => CoreStrings.Get("Shortcuts/ConflictNeedsModifier"),
        ShortcutConflictKind.SystemReserved => CoreStrings.Format("Shortcuts/ConflictSystemReserved", chord),
        ShortcutConflictKind.Reserved => CoreStrings.Format("Shortcuts/ConflictReserved", chord, Name),
        ShortcutConflictKind.Command => CoreStrings.Format("Shortcuts/ConflictCommand", chord, Command!.Title, Command.Category.DisplayName()),
        _ => string.Empty,
    };
}

/// <summary>Decides whether a recorded chord can be bound to a command, checked in the order the user would care about.</summary>
public static class ShortcutConflictResolver
{
    public static ShortcutConflict Resolve(KeyChord chord, ShortcutCommand command, ShortcutMap map)
    {
        if (chord.IsEmpty)
        {
            return ShortcutConflict.None;
        }

        if (ReservedShortcuts.IsSystemReserved(chord))
        {
            return new ShortcutConflict(ShortcutConflictKind.SystemReserved);
        }

        if (!command.Accepts(chord))
        {
            return new ShortcutConflict(ShortcutConflictKind.NeedsModifier);
        }

        if (ReservedShortcuts.ConflictFor(chord, command.Context) is { } name)
        {
            return new ShortcutConflict(ShortcutConflictKind.Reserved, name);
        }

        return map.FindConflict(chord, command) is { } other
            ? new ShortcutConflict(ShortcutConflictKind.Command, Command: other)
            : ShortcutConflict.None;
    }

    /// <summary>
    /// What is wrong with the chord a command has now, for a warning beside it: another command with the same chord
    /// (possible after hand-editing the settings file) or a reserved key it can never win.
    /// </summary>
    public static ShortcutConflict Current(ShortcutCommand command, ShortcutMap map) =>
        Resolve(map.ChordFor(command), command, map);
}
