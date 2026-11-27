using Microsoft.UI.Xaml;
using TablePro.App.Model;
using TablePro.DataGrid;
using TablePro.Editor;
using TablePro.Editor.Model;
using TablePro.Interop;

namespace TablePro.App.Services;

// The display settings every editor and grid follows: applied as each one loads and again when Settings changes
// them, so an open tab takes a change at once.
internal static class DisplaySettings
{
    private static AppSettings s_current = new();
    private static EditorKeymap s_editorKeymap = EditorKeymap.Default;

    private static event EventHandler? Changed;

    // TablePro's keys with the chosen preset laid over them; menus, tooltips and editors read it.
    public static EffectiveKeymap Keymap { get; private set; } = EffectiveKeymap.TablePro;

    // As Windows words the command's first key; a single space when it has none, as a menu item takes it.
    public static string KeyLabel(string action) => Keymap.Label(action, Word);

    // A button's tooltip: its name, then its keys when it has any.
    public static string Tip(string name, string action) => Keymap.KeysOf(action).Count == 0
        ? name
        : Strings.Format("TipWithKeys", name, KeyLabel(action));

    public static void Update(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var before = s_current;
        s_current = settings;
        var keysMoved = before.ShortcutPreset != settings.ShortcutPreset
            || !before.ShortcutOverrides.Equals(settings.ShortcutOverrides);
        if (keysMoved)
        {
            Keymap = Resolve(settings.ShortcutPreset, settings.ShortcutOverrides);
            s_editorKeymap = EditorKeys(Keymap);
        }

        if (keysMoved
            || before.EditorFontSize != settings.EditorFontSize
            || before.EditorFontFamily != settings.EditorFontFamily
            || before.WordWrap != settings.WordWrap
            || before.CodeFolding != settings.CodeFolding
            || before.VimMode != settings.VimMode
            || before.HighlightCurrentStatement != settings.HighlightCurrentStatement
            || before.EditorLightScheme != settings.EditorLightScheme
            || before.EditorDarkScheme != settings.EditorDarkScheme
            || before.GridFontFamily != settings.GridFontFamily
            || before.GridFontSize != settings.GridFontSize
            || before.NullDisplay != settings.NullDisplay)
        {
            Changed?.Invoke(null, EventArgs.Empty);
        }
    }

    public static void Follow(DataGridView grid)
    {
        ArgumentNullException.ThrowIfNull(grid);
        Follow(grid, () =>
        {
            grid.NullText = s_current.NullDisplay;
            grid.CellFontFamily = s_current.GridFontFamily;
            grid.CellFontSize = s_current.GridFontSize;
        });
    }

    public static void Follow(SqlEditor editor)
    {
        ArgumentNullException.ThrowIfNull(editor);
        Follow(editor, () =>
        {
            editor.EditorFontFamily = s_current.EditorFontFamily;
            editor.EditorFontSize = (float)s_current.EditorFontSize;
            editor.WordWrap = s_current.WordWrap;
            editor.IsFoldingEnabled = s_current.CodeFolding;
            editor.IsVimEnabled = s_current.VimMode;
            editor.HighlightsCurrentStatement = s_current.HighlightCurrentStatement;
            editor.LightColorScheme = s_current.EditorLightScheme;
            editor.DarkColorScheme = s_current.EditorDarkScheme;
            editor.Keymap = s_editorKeymap;
        });
    }

    // A view whose tooltips name keys words them again when the preset changes.
    public static void FollowKeys(FrameworkElement element, Action apply)
    {
        ArgumentNullException.ThrowIfNull(element);
        ArgumentNullException.ThrowIfNull(apply);
        Follow(element, apply);
    }

    private static string Word(string id) => Strings.Get("Key_" + id);

    // A preset the core does not know, or cannot read, keeps TablePro's keys; the user's overrides lay over the result.
    private static EffectiveKeymap Resolve(string? preset, ShortcutOverrideMap overrides)
    {
        var customs = ShortcutOverrides.From(overrides);
        if (preset is null && customs.Count == 0)
        {
            return EffectiveKeymap.TablePro;
        }

        IReadOnlyList<KeymapBinding>? bindings = null;
        if (preset is not null)
        {
            try
            {
                bindings = TableProCore.KeymapPreset(preset, KeymapPlatform.Windows);
            }
            catch (TableProException)
            {
                bindings = null;
            }
        }

        return Model.Keymap.Resolve(bindings, customs);
    }

    private static EditorKeymap EditorKeys(EffectiveKeymap keymap)
    {
        var actions = Model.Keymap.EditorActions;
        var none = actions.Where(pair => keymap.KeysOf(pair.Action).Count == 0).Select(pair => pair.Command);
        var rows = actions
            .SelectMany(pair => keymap.KeysOf(pair.Action)
                .Select(key => (pair.Command, new EditorKey(key.Key, key.Control, key.Alt, key.Shift))))
            .ToList();
        return EditorKeymap.Default.Without(none).With(rows);
    }

    // A tab not on screen is unloaded and hears nothing, so it applies the settings again as it loads.
    private static void Follow(FrameworkElement element, Action apply)
    {
        void OnChanged(object? sender, EventArgs e) => apply();
        element.Loaded += (_, _) =>
        {
            Changed -= OnChanged;
            Changed += OnChanged;
            apply();
        };
        element.Unloaded += (_, _) => Changed -= OnChanged;
        apply();
    }
}
