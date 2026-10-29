using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TablePro.App.Services;
using TablePro.Core.Updates;

namespace TablePro.App.Views;

public sealed partial class SettingsWindow
{
    /// <summary>The Updates cards on the General page, as macOS keeps them in Settings > General.</summary>
    private void AddUpdateCards(StackPanel page)
    {
        if (_host.Updates is not { } updates)
        {
            return;
        }

        var status = new TextBlock { Text = updates.StatusText, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        void Refresh() => status.Text = updates.StatusText;
        EventHandler onChanged = (_, _) => Refresh();
        updates.Changed += onChanged;
        Closed += (_, _) => updates.Changed -= onChanged;

        if (!updates.CanCheck)
        {
            page.Children.Add(Card(Strings.Get("Updates/SettingsTitle"), updates.StatusText, new TextBlock()));
            return;
        }

        page.Children.Add(Card(Strings.Get("Updates/AutoCheckTitle"), Strings.Get("Updates/AutoCheckDescription"), Toggle(updates.Preferences.AutomaticallyChecks, updates.SetAutomaticallyChecksAsync)));
        if (updates.CanChooseChannel)
        {
            page.Children.Add(Card(Strings.Get("Updates/BetaTitle"), Strings.Get("Updates/BetaDescription"), Toggle(
                updates.Preferences.Channel == UpdateChannel.Beta,
                on => updates.SetChannelAsync(on ? UpdateChannel.Beta : UpdateChannel.Stable))));
        }

        var check = new Button { Content = Strings.Get("Updates/CheckNow") };
        check.Click += async (_, _) =>
        {
            check.IsEnabled = false;
            try
            {
                await UpdateDialogs.CheckAsync(updates, new DialogService(this));
            }
            finally
            {
                check.IsEnabled = true;
                Refresh();
            }
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(status);
        row.Children.Add(check);
        page.Children.Add(Card(Strings.Format("Updates/VersionTitle", updates.CurrentVersion), null, row));
    }
}
