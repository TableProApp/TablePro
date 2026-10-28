using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.ViewModels;

namespace TablePro.App.Views;

/// <summary>Section headers and objects share one flat, virtualized list rather than nested groups.</summary>
public sealed partial class SidebarTemplateSelector : DataTemplateSelector
{
    public DataTemplate? Header { get; set; }

    public DataTemplate? Item { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) =>
        item is SidebarEntry { IsHeader: true } ? Header : Item;

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container)
    {
        if (container is ListViewItem listItem)
        {
            var header = item is SidebarEntry { IsHeader: true };
            listItem.IsHitTestVisible = !header;
            listItem.IsTabStop = !header;
            listItem.MinHeight = header ? 28 : 32;
        }

        return SelectTemplateCore(item);
    }
}
