using Microsoft.UI.Xaml.Automation;
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

    // The header menu's Wrap text, checked while the tab's rows wrap, as View > Wrap text is.
    public static ToggleMenuFlyoutItem WrapText(ITabContent tab)
    {
        var wraps = tab.WrapsText ?? false;
        var item = new ToggleMenuFlyoutItem
        {
            Text = Strings.Get("GridMenuWrapText"),
            IsChecked = wraps,
            IsEnabled = tab.WrapsText is not null,
        };
        AutomationProperties.SetAutomationId(item, "GridMenuWrapText");
        item.Click += (_, _) => tab.SetWrapsText(!wraps);
        return item;
    }

    public static MenuFlyoutItem Copy(DataGridView grid) =>
        Item("GridMenuCopy", grid.RowCount > 0, async () => await grid.CopySelectionAsync().ConfigureAwait(true), Symbol.Copy);

    public static MenuFlyoutItem ViewValue(ResultsPane results) =>
        Item("GridMenuViewValue", results.CanViewValue, async () => await results.ViewValueAsync().ConfigureAwait(true));

    // From the keyboard the menu opens at the cell it acts on, not over the editor; a pointer's opens where it was.
    public static void Show(MenuFlyout menu, DataGridView grid, ContextRequestedEventArgs args) =>
        Show(menu, grid, Place(grid, args));

    // Read while the request is raised, for a menu built after an await.
    public static FlyoutShowOptions? Place(DataGridView grid, ContextRequestedEventArgs args)
    {
        if (args.TryGetPosition(grid, out var point))
        {
            return new FlyoutShowOptions { Position = point };
        }

        return grid.FocusedCellMenuPoint() is { } cell ? new FlyoutShowOptions { Position = cell } : null;
    }

    public static void Show(MenuFlyout menu, DataGridView grid, FlyoutShowOptions? options)
    {
        if (options is not null)
        {
            menu.ShowAt(grid, options);
        }
        else
        {
            menu.ShowAt(grid);
        }
    }
}
