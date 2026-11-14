using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Services;
using TablePro.DataGrid;

namespace TablePro.App.Views;

// What a results grid's menu holds in every tab, and where it opens.
internal static class GridMenus
{
    public static MenuFlyoutItem Item(string text, bool enabled, Action invoke, Symbol? icon = null)
    {
        var item = new MenuFlyoutItem { Text = Strings.Get(text), IsEnabled = enabled };
        if (icon is { } symbol)
        {
            item.Icon = new SymbolIcon(symbol);
        }

        item.Click += (_, _) => invoke();
        return item;
    }

    public static MenuFlyoutItem Copy(DataGridView grid) =>
        Item("GridMenuCopy", grid.RowCount > 0, async () => await grid.CopySelectionAsync().ConfigureAwait(true), Symbol.Copy);

    public static MenuFlyoutItem ViewValue(ResultsPane results) =>
        Item("GridMenuViewValue", results.CanViewValue, async () => await results.ViewValueAsync().ConfigureAwait(true));

    // From the keyboard the menu opens at the cell it acts on, not over the editor; a pointer's opens where it was.
    public static void Show(MenuFlyout menu, DataGridView grid, ContextRequestedEventArgs args)
    {
        if (args.TryGetPosition(grid, out var point))
        {
            menu.ShowAt(grid, new FlyoutShowOptions { Position = point });
        }
        else if (grid.FocusedCellMenuPoint() is { } cell)
        {
            menu.ShowAt(grid, new FlyoutShowOptions { Position = cell });
        }
        else
        {
            menu.ShowAt(grid);
        }
    }
}
