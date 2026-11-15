using Microsoft.UI.Xaml;
using TablePro.App.Model;
using TablePro.DataGrid;
using TablePro.Editor;

namespace TablePro.App.Services;

// The font and NULL settings every editor and grid follows: applied as each one loads and again when Settings changes
// them, so an open tab takes a change at once.
internal static class DisplaySettings
{
    private static AppSettings s_current = new();

    private static event EventHandler? Changed;

    public static void Update(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        var before = s_current;
        s_current = settings;
        if (before.EditorFontSize != settings.EditorFontSize
            || before.EditorFontFamily != settings.EditorFontFamily
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
        });
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
