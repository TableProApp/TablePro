namespace TablePro.App.Model;

public static class SessionTabs
{
    // Definition and key tabs are left out: an older build reads an unknown TabKind as a broken file and loses the session.
    public static (IReadOnlyList<SessionTab> Tabs, int Selected) Persisted(
        IReadOnlyList<SessionTab> tabs,
        int selected)
    {
        ArgumentNullException.ThrowIfNull(tabs);
        List<SessionTab> kept = [];
        var keptSelected = 0;
        for (var index = 0; index < tabs.Count; index++)
        {
            if (tabs[index].Kind is TabKind.Definition or TabKind.Key)
            {
                continue;
            }

            // A left-out tab that was selected hands the selection to the nearest kept tab before it.
            if (index <= selected)
            {
                keptSelected = kept.Count;
            }

            kept.Add(tabs[index]);
        }

        return (kept, keptSelected);
    }
}
