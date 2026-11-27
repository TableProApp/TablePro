using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Model.QuickSwitcher;

namespace TablePro.App.Services;

// The palette's Commands source: the window's keyed menu actions as rows that run them, so the palette can do what the
// menu bar does. It reads each item's current enabled state, so a command that cannot run now is left out.
internal static class PaletteCommands
{
    public static (IReadOnlyList<PaletteItem> Items, IReadOnlyDictionary<string, Action> Invoke) Build(
        IReadOnlyList<(MenuFlyoutItem Item, string Action)> menu)
    {
        ArgumentNullException.ThrowIfNull(menu);
        var items = new List<PaletteItem>();
        var invoke = new Dictionary<string, Action>(StringComparer.Ordinal);
        foreach (var (item, action) in menu)
        {
            // The palette never lists the key that opened it.
            if (string.Equals(action, "quickSwitcher", StringComparison.Ordinal)
                || !item.IsEnabled
                || string.IsNullOrWhiteSpace(item.Text)
                || invoke.ContainsKey(action))
            {
                continue;
            }

            items.Add(new PaletteItem
            {
                FrecencyKey = "command:" + action,
                Name = item.Text,
                Kind = PaletteItemKind.Command,
                Action = action,
            });
            var target = item;
            invoke[action] = () => Run(target);
        }

        return (items, invoke);
    }

    // Runs the item through its automation peer, which raises the same Click the menu does, so one path serves both.
    private static void Run(MenuFlyoutItem item)
    {
        if (FrameworkElementAutomationPeer.CreatePeerForElement(item)?.GetPattern(PatternInterface.Invoke) is IInvokeProvider provider)
        {
            provider.Invoke();
        }
    }
}
