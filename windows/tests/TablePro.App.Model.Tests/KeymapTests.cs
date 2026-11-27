using TablePro.Interop;

namespace TablePro.App.Model.Tests;

// Each preset's Windows rows from the core's keymaps.json over TablePro's keys: what moves, what is refused, what is
// left with no key (core 0058, windows/docs/decisions/0025).
public sealed class KeymapTests
{
    private static readonly Dictionary<string, string> English = new(StringComparer.Ordinal)
    {
        ["Ctrl"] = "Ctrl",
        ["Alt"] = "Alt",
        ["Shift"] = "Shift",
        ["Join"] = "{0}+{1}",
        ["Enter"] = "Enter",
        ["Backspace"] = "Backspace",
        ["Insert"] = "Insert",
        ["Delete"] = "Delete",
    };

    public static TheoryData<string, Dictionary<string, string>, string[]> Goldens => new()
    {
        {
            "tableplus",
            new()
            {
                ["executeQuery"] = "ctrl+enter",
                ["executeAllStatements"] = "ctrl+shift+enter",
                ["formatQuery"] = "ctrl+i",
                ["newTab"] = "ctrl+e",
                ["refresh"] = "ctrl+r",
                // Its Ctrl+Shift+Backspace deletes a word in the editor, so Discard changes keeps no key.
                ["duplicateRow"] = "ctrl+d",
                ["showSettings"] = "ctrl+,",
                ["cancelQuery"] = "ctrl+.",
            },
            []
        },
        {
            "dbeaver",
            new()
            {
                ["executeQuery"] = "ctrl+enter",
                ["executeAllStatements"] = "ctrl+shift+enter",
                ["newConnection"] = "ctrl+shift+n",
                ["addRow"] = "alt+insert",
                ["discardChanges"] = "ctrl+r",
            },
            []
        },
        {
            "datagrip",
            new()
            {
                ["executeQuery"] = "ctrl+enter",
                ["executeAllStatements"] = "ctrl+shift+enter",
                ["newTab"] = "ctrl+shift+q",
                ["refresh"] = "ctrl+f5",
                ["addRow"] = "alt+insert",
                ["duplicateRow"] = "ctrl+d",
                ["findAndReplace"] = "ctrl+r",
                ["cancelQuery"] = "ctrl+f2",
            },
            []
        },
        {
            "beekeeperstudio",
            new()
            {
                ["addRow"] = "ctrl+n",
                ["duplicateRow"] = "ctrl+d",
                ["newConnection"] = string.Empty,
            },
            ["newConnection"]
        },
        {
            "navicat",
            new()
            {
                ["executeQuery"] = "ctrl+shift+r",
                ["executeAllStatements"] = "ctrl+r",
                ["newTab"] = "ctrl+q",
                ["addRow"] = "ctrl+n",
                ["toggleHistory"] = "ctrl+l",
                ["showSettings"] = "ctrl+,",
                ["cancelQuery"] = "ctrl+t",
                ["newConnection"] = string.Empty,
            },
            ["newConnection"]
        },
        {
            "dbx",
            new()
            {
                ["executeQuery"] = "ctrl+enter",
                ["executeAllStatements"] = "ctrl+shift+enter",
                ["addRow"] = "ctrl+n",
                ["duplicateRow"] = "ctrl+d",
                ["findAndReplace"] = "ctrl+r",
                ["showSettings"] = "ctrl+,",
                ["newConnection"] = string.Empty,
            },
            ["newConnection"]
        },
    };

    [Fact]
    public void TableProKeepsTheKeysOfAdr0002And0004()
    {
        var keymap = EffectiveKeymap.TablePro;

        Assert.Equal(Movable(Keymap.Resolve([])), Movable(keymap));
        Assert.Empty(keymap.Displaced);
        Assert.Equal("ctrl+enter", Keys(keymap, "executeAllStatements"));
        Assert.Equal("ctrl+shift+enter", Keys(keymap, "executeQuery"));
        Assert.Equal("ctrl+shift+f", Keys(keymap, "formatQuery"));
        Assert.Equal("ctrl+shift+f", Keys(keymap, "toggleFilters"));
        Assert.Equal("f5", Keys(keymap, "refresh"));
        Assert.Equal(string.Empty, Keys(keymap, "discardChanges"));
        Assert.Equal("ctrl+y", Keys(keymap, "redo"));
    }

    [Theory]
    [MemberData(nameof(Goldens))]
    public void EachPresetMovesWhatTheGoldenSays(string id, Dictionary<string, string> moved, string[] displaced)
    {
        var keymap = Keymap.Resolve(TableProCore.KeymapPreset(id, KeymapPlatform.Windows));
        var expected = Movable(EffectiveKeymap.TablePro);
        foreach (var (action, keys) in moved)
        {
            expected[action] = keys;
        }

        Assert.Equal(expected, Movable(keymap));
        Assert.Equal(displaced, keymap.Displaced);
    }

    [Fact]
    public void EveryWindowsPresetIsCoveredByAGolden()
    {
        Assert.Equal(
            TableProCore.KeymapPresets(KeymapPlatform.Windows).Select(preset => preset.Id),
            Goldens.Select(row => row.Data.Item1));
    }

    [Theory]
    [InlineData("newTab", "ctrl+alt+t")]
    [InlineData("newTab", "alt+t")]
    [InlineData("toggleTableBrowser", "alt+1")]
    [InlineData("addRow", "insert")]
    [InlineData("addRow", "shift+n")]
    [InlineData("newTab", "ctrl+]")]
    [InlineData("newTab", "ctrl+'")]
    [InlineData("newTab", "ctrl+z")]
    [InlineData("newTab", "ctrl+a")]
    [InlineData("newTab", "ctrl+3")]
    [InlineData("newTab", "ctrl+tab")]
    [InlineData("closeTab", "ctrl+f4")]
    [InlineData("newTab", "f1")]
    [InlineData("newConnection", "ctrl+shift+k")]
    [InlineData("toggleTableBrowser", "ctrl+0")]
    [InlineData("find", "ctrl+]")]
    [InlineData("formatQuery", "ctrl+alt+l")]
    public void ARowWindowsRefusesIsDroppedAndItsCommandKeepsItsKey(string action, string chord)
    {
        var keymap = Keymap.Resolve([Binding(action, chord)]);

        Assert.Equal(Movable(EffectiveKeymap.TablePro), Movable(keymap));
        Assert.Empty(keymap.Displaced);
    }

    [Theory]
    [InlineData("discardChanges", "ctrl+shift+backspace")]
    [InlineData("saveChanges", "ctrl+shift+delete")]
    [InlineData("refresh", "alt+backspace")]
    [InlineData("cancelQuery", "ctrl+f3")]
    [InlineData("toggleHistory", "ctrl+shift+pageup")]
    [InlineData("executeQuery", "shift+alt+left")]
    [InlineData("newTab", "ctrl+-")]
    [InlineData("newConnection", "ctrl+shift+/")]
    [InlineData("findAndReplace", "alt+delete")]
    public void ARowOnAKeyTheEditorAnswersIsDroppedAndItsCommandKeepsItsKey(string action, string chord)
    {
        var keymap = Keymap.Resolve([Binding(action, chord)]);

        Assert.Equal(Movable(EffectiveKeymap.TablePro), Movable(keymap));
        Assert.Empty(keymap.Displaced);
    }

    [Fact]
    public void AKeyTheEditorAnswersStillServesAGridCommand()
    {
        var keymap = Keymap.Resolve([Binding("duplicateRow", "ctrl+shift+backspace")]);

        Assert.Equal("ctrl+shift+backspace", Keys(keymap, "duplicateRow"));
    }

    [Fact]
    public void ARowWithTheWindowsKeyIsDropped()
    {
        var keymap = Keymap.Resolve([Binding("newTab", "ctrl+e") with { Command = true }]);

        Assert.Equal("ctrl+t", Keys(keymap, "newTab"));
    }

    [Theory]
    [InlineData("showNextTab", "ctrl+pagedown")]
    [InlineData("delete", "ctrl+delete")]
    [InlineData("quickSwitcher", "ctrl+p")]
    [InlineData("explainQuery", "ctrl+shift+e")]
    public void ARowForAFixedCommandOrOneWindowsLacksMovesNothing(string action, string chord)
    {
        var keymap = Keymap.Resolve([Binding(action, chord)]);

        Assert.Equal(Movable(EffectiveKeymap.TablePro), Movable(keymap));
        Assert.Equal("ctrl+p", Keys(keymap, "focusSidebarSearch"));
        Assert.Equal("ctrl+shift+e", Keys(keymap, "exportResults"));
    }

    [Fact]
    public void KeysInScopesThatNeverMeetAreKeptSideBySide()
    {
        var keymap = Keymap.Resolve([Binding("duplicateRow", "ctrl+d"), Binding("toggleFilters", "ctrl+f")]);

        Assert.Equal("ctrl+d", Keys(keymap, "duplicateRow"));
        Assert.Equal("ctrl+f", Keys(keymap, "toggleFilters"));
        Assert.Equal("ctrl+f", Keys(keymap, "find"));
        Assert.Empty(keymap.Displaced);
    }

    [Fact]
    public void AMenuKeyThatReachesTheEditorTakesItFromTheEditor()
    {
        var keymap = Keymap.Resolve([Binding("newTab", "ctrl+f")]);

        Assert.Equal("ctrl+f", Keys(keymap, "newTab"));
        Assert.Equal(string.Empty, Keys(keymap, "find"));
        Assert.Equal(["find"], keymap.Displaced);
    }

    [Fact]
    public void ALabelIsWordedAsWindowsWordsItAndASpaceForNone()
    {
        var keymap = Keymap.Resolve(
        [
            Binding("addRow", "alt+insert"),
            Binding("showSettings", "ctrl+,"),
            Binding("duplicateRow", "ctrl+shift+backspace"),
        ]);

        Assert.Equal("Ctrl+Shift+F", keymap.Label("formatQuery", Word));
        Assert.Equal("Shift+F5", keymap.Label("cancelQuery", Word));
        Assert.Equal("Ctrl+Enter", keymap.Label("executeAllStatements", Word));
        Assert.Equal("Alt+Insert", keymap.Label("addRow", Word));
        Assert.Equal("Ctrl+,", keymap.Label("showSettings", Word));
        Assert.Equal("Ctrl+Shift+Backspace", keymap.Label("duplicateRow", Word));
        Assert.Equal("Delete", keymap.Label("delete", Word));
        Assert.Equal("Ctrl+Y", keymap.Label("redo", Word));
        Assert.Equal(" ", keymap.Label("toggleHistory", Word));
    }

    [Theory]
    [InlineData("ctrl+shift+f", true)]
    [InlineData("shift+ctrl+f", true)]
    [InlineData("ctrl+=", true)]
    [InlineData("ctrl+f12", true)]
    [InlineData("ctrl+pagedown", true)]
    [InlineData("ctrl+", false)]
    [InlineData("ctrl+ctrl+f", false)]
    [InlineData("cmd+f", false)]
    [InlineData("ctrl+nope", false)]
    [InlineData("", false)]
    public void AChordParsesFromTheKeymapFilesText(string text, bool parses)
    {
        Assert.Equal(parses, KeyChord.TryParse(text, out var chord));
        if (parses)
        {
            Assert.Equal(text.Contains("shift", StringComparison.Ordinal), chord!.Shift);
            Assert.True(chord.Control);
        }
    }

    [Fact]
    public void AnOverrideWinsOverTheDefaultAndThePreset()
    {
        var overrides = ShortcutOverrides.None.Assigning("newTab", KeyChord.Parse("ctrl+shift+j"));

        Assert.Equal("ctrl+shift+j", Keys(Keymap.Resolve(null, overrides), "newTab"));
        var preset = TableProCore.KeymapPreset("tableplus", KeymapPlatform.Windows);
        Assert.Equal("ctrl+shift+j", Keys(Keymap.Resolve(preset, overrides), "newTab"));
    }

    [Fact]
    public void AnOverrideDisplacesAConflictingCommandAPressCanReach()
    {
        var overrides = ShortcutOverrides.None.Assigning("duplicateRow", KeyChord.Parse("ctrl+shift+n"));
        var keymap = Keymap.Resolve(null, overrides);

        Assert.Equal("ctrl+shift+n", Keys(keymap, "duplicateRow"));
        Assert.Equal(string.Empty, Keys(keymap, "addRow"));
        Assert.Equal(["addRow"], keymap.Displaced);
    }

    [Fact]
    public void TheClearedSentinelRemovesAKeyWithoutCountingAsDisplaced()
    {
        var keymap = Keymap.Resolve(null, ShortcutOverrides.None.Clearing("refresh"));

        Assert.Equal(string.Empty, Keys(keymap, "refresh"));
        Assert.Empty(keymap.Displaced);
    }

    [Theory]
    [InlineData("newTab", "ctrl+alt+t")]
    [InlineData("find", "ctrl+[")]
    [InlineData("newTab", "ctrl+z")]
    public void AnOverrideTheGatesRejectLeavesTheKeyAsItWas(string action, string chord)
    {
        var before = Keys(EffectiveKeymap.TablePro, action);
        var overrides = ShortcutOverrides.None.Assigning(action, KeyChord.Parse(chord));

        Assert.Equal(before, Keys(Keymap.Resolve(null, overrides), action));
    }

    [Fact]
    public void ClassifyCapturesAFreeChord()
    {
        var decision = Keymap.Classify("newTab", KeyChord.Parse("ctrl+shift+j"), EffectiveKeymap.TablePro);

        Assert.Equal(ShortcutCapture.Capture, decision.Kind);
        Assert.Empty(decision.Holders);
    }

    [Fact]
    public void ClassifyAsksBeforeTakingAChordAnotherCommandHolds()
    {
        var decision = Keymap.Classify("duplicateRow", KeyChord.Parse("ctrl+shift+n"), EffectiveKeymap.TablePro);

        Assert.Equal(ShortcutCapture.Reassign, decision.Kind);
        Assert.Equal(["addRow"], decision.Holders);
    }

    [Theory]
    [InlineData("newTab", "ctrl+alt+t", ShortcutRefusal.NeedsModifier)]
    [InlineData("newTab", "q", ShortcutRefusal.NeedsModifier)]
    [InlineData("newTab", "ctrl+`", ShortcutRefusal.UnavailableKey)]
    [InlineData("newTab", "ctrl+z", ShortcutRefusal.Reserved)]
    public void ClassifyRefusesAChordTheGatesReject(string action, string chord, ShortcutRefusal reason)
    {
        var decision = Keymap.Classify(action, KeyChord.Parse(chord), EffectiveKeymap.TablePro);

        Assert.Equal(ShortcutCapture.Refuse, decision.Kind);
        Assert.Equal(reason, decision.Reason);
    }

    [Fact]
    public void ReassigningClearsTheOtherHolderAndBindsTheAction()
    {
        var overrides = ShortcutOverrides.None.Assigning("addRow", KeyChord.Parse("ctrl+shift+j"));
        var reassigned = overrides.Reassigning("duplicateRow", KeyChord.Parse("ctrl+shift+j"), ["addRow"]);
        var keymap = Keymap.Resolve(null, reassigned);

        Assert.Equal("ctrl+shift+j", Keys(keymap, "duplicateRow"));
        Assert.Equal(string.Empty, Keys(keymap, "addRow"));
    }

    [Fact]
    public void NormalizeDropsUnknownAndRejectedOverridesAndKeepsTheClearedSentinel()
    {
        var settings = new AppSettings
        {
            ShortcutOverrides = new ShortcutOverrideMap
            {
                ["newTab"] = "ctrl+shift+j",
                ["refresh"] = string.Empty,
                ["noSuchCommand"] = "ctrl+j",
                ["addRow"] = "ctrl+alt+x",
                ["find"] = "ctrl+[",
            },
        }.Normalized();

        Assert.Equal(2, settings.ShortcutOverrides.Count);
        Assert.Equal("ctrl+shift+j", settings.ShortcutOverrides["newTab"]);
        Assert.Equal(string.Empty, settings.ShortcutOverrides["refresh"]);
    }

    [Fact]
    public void TheOverridesMapKeepsSettingsValueEquality()
    {
        Assert.Equal(new AppSettings(), new AppSettings());
        Assert.Equal(new AppSettings().Normalized(), new AppSettings());
    }

    private static string Word(string id) => English[id];

    private static KeymapBinding Binding(string action, string chord)
    {
        var parsed = KeyChord.Parse(chord);
        return new KeymapBinding(action, parsed.Key, parsed.Control, parsed.Shift, parsed.Alt, false, false);
    }

    private static string Keys(EffectiveKeymap keymap, string action) =>
        string.Join(' ', keymap.KeysOf(action).Select(chord => chord.ToString()));

    private static Dictionary<string, string> Movable(EffectiveKeymap keymap) => Keymap.Commands
        .Where(command => command.Owner != CommandOwner.Fixed)
        .Select(command => command.Action)
        .Distinct()
        .ToDictionary(action => action, action => Keys(keymap, action));
}
