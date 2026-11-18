using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Services;
using TablePro.Interop;
using Windows.System;

namespace TablePro.App.Views;

// The AI section: the provider, the compatible server's address, the key in Credential Manager and the model.
public sealed partial class SettingsView
{
    // Counts key reads and writes, so one that lands after the provider changed, or after a later one, is not shown.
    private int _keyRead;
    private CancellationTokenSource? _listingModels;

    private AiProvider? ChosenProvider => (AiProviderBox.SelectedItem as ComboBoxItem)?.Tag as AiProvider?;

    // Called while _loading is set, so nothing here writes the settings back.
    private void LoadAssistant()
    {
        var settings = _workbench.Settings;
        AiProviderBox.Items.Clear();
        AiProviderBox.Items.Add(new ComboBoxItem { Content = Strings.Get("AiProviderOff") });
        foreach (var info in AiAssistant.Providers)
        {
            AiProviderBox.Items.Add(new ComboBoxItem { Content = AssistantText.ProviderName(info.Provider), Tag = info.Provider });
        }

        AiProviderBox.SelectedItem = AiProviderBox.Items
            .OfType<ComboBoxItem>()
            .First(item => (item.Tag as AiProvider?) == settings.AiProvider);
        AiAddressBox.Text = settings.CompatibleAddress;
        ShowProvider(settings.AiProvider);
    }

    private void ShowProvider(AiProvider? provider)
    {
        var on = provider is not null;
        var compatible = provider == AiProvider.OpenAICompatible;
        AiProviderCard.Description = Strings.Get(on ? "AiProviderOnDescription" : "AiProviderOffDescription");
        AiAddressCard.Visibility = compatible ? Visibility.Visible : Visibility.Collapsed;
        AiKeyCard.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        AiModelCard.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        AiKeyCard.Header = Strings.Get(compatible ? "AiKeyOptionalHeader" : "AiKeyHeader");
        AiKeyBox.Password = string.Empty;
        AiKeyRemoveButton.Visibility = Visibility.Collapsed;
        AiStatusText.Text = string.Empty;
        _listingModels?.Cancel();
        AiModelBox.Items.Clear();
        AiModelBox.Text = provider is { } chosen ? _workbench.Settings.ModelOf(chosen) : string.Empty;
        if (compatible)
        {
            CheckAddress(AiAddressBox.Text);
        }

        if (provider is { } shown)
        {
            ReadKeyState(shown);
        }
    }

    private void OnAiProviderChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }

        var provider = ChosenProvider;
        _workbench.UpdateSettings(settings => settings with { AiProvider = provider });
        ShowProvider(provider);
    }

    private void OnAiAddressChanged(object sender, TextChangedEventArgs e)
    {
        if (_loading)
        {
            return;
        }

        var address = AiAddressBox.Text;
        _workbench.UpdateSettings(settings => settings with { CompatibleAddress = address });
        CheckAddress(address);
    }

    private void CheckAddress(string address)
    {
        var valid = AiAssistant.IsValidAddress(address.Trim());
        AiAddressCard.Description = Strings.Get(valid ? "AiAddressDescription" : "AiAddressInvalid");
        AutomationProperties.SetHelpText(AiAddressBox, valid ? string.Empty : Strings.Get("AiAddressInvalid"));
    }

    // Read when the provider shows, so Credential Manager is asked only once the user looks here.
    private async void ReadKeyState(AiProvider provider)
    {
        var read = ++_keyRead;
        bool? kept;
        string? problem = null;
        try
        {
            kept = await _workbench.Core.Assistant.HasKeyAsync(provider).ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            kept = null;
            problem = AssistantText.Error(exception.Error);
        }

        if (read != _keyRead || ChosenProvider != provider)
        {
            return;
        }

        AiKeyCard.Description = kept switch
        {
            true => Strings.Get("AiKeyKept"),
            false => Strings.Get(provider == AiProvider.OpenAICompatible ? "AiKeyNoneOptional" : "AiKeyNone"),
            null => problem ?? string.Empty,
        };
        AiKeyRemoveButton.Visibility = kept == true ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnAiKeyTyped(object sender, RoutedEventArgs e) =>
        AiKeySaveButton.IsEnabled = !string.IsNullOrWhiteSpace(AiKeyBox.Password);

    private async void OnAiKeyKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter && AiKeySaveButton.IsEnabled)
        {
            e.Handled = true;
            await SaveKeyAsync(AiKeyBox.Password).ConfigureAwait(true);
        }
    }

    private async void OnAiKeySave(object sender, RoutedEventArgs e) =>
        await SaveKeyAsync(AiKeyBox.Password).ConfigureAwait(true);

    private async void OnAiKeyRemove(object sender, RoutedEventArgs e) =>
        await SaveKeyAsync(string.Empty).ConfigureAwait(true);

    // A blank key removes the one kept.
    private async Task SaveKeyAsync(string key)
    {
        if (ChosenProvider is not { } provider)
        {
            return;
        }

        var read = ++_keyRead;
        AiKeySaveButton.IsEnabled = false;
        AiKeyRemoveButton.IsEnabled = false;
        string status;
        var saved = false;
        try
        {
            await _workbench.Core.Assistant.SetKeyAsync(provider, key).ConfigureAwait(true);
            status = Strings.Get(key.Length == 0 ? "AiKeyRemoved" : "AiKeySaved");
            saved = true;
        }
        catch (TableProException exception)
        {
            status = AssistantText.Error(exception.Error);
        }
        finally
        {
            AiKeyRemoveButton.IsEnabled = true;
            AiKeySaveButton.IsEnabled = !string.IsNullOrWhiteSpace(AiKeyBox.Password);
        }

        // A key typed for another provider, or after this save began, stays in the box.
        if (read == _keyRead && ChosenProvider == provider)
        {
            if (saved && AiKeyBox.Password == key)
            {
                AiKeyBox.Password = string.Empty;
            }

            AiStatusText.Text = status;
            ReadKeyState(provider);
        }
    }

    // The list is read again each time it opens, since a server's models change as they are pulled.
    private async void OnAiModelsOpened(object sender, object e)
    {
        if (ChosenProvider is not { } provider)
        {
            return;
        }

        _listingModels?.Cancel();
        using var listing = new CancellationTokenSource();
        _listingModels = listing;
        IReadOnlyList<string> models;
        try
        {
            AiStatusText.Text = Strings.Get("AiModelsReading");
            models = await _workbench.Core.Assistant
                .ListModelsAsync(_workbench.Settings.AssistantFor(provider), listing.Token)
                .ConfigureAwait(true);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (TableProException exception)
        {
            if (!listing.IsCancellationRequested)
            {
                AiStatusText.Text = Strings.Format("AiModelsFailed", AssistantText.Error(exception.Error));
            }

            return;
        }
        finally
        {
            if (ReferenceEquals(_listingModels, listing))
            {
                _listingModels = null;
            }
        }

        if (listing.IsCancellationRequested || ChosenProvider != provider)
        {
            return;
        }

        AiStatusText.Text = models.Count == 0 ? Strings.Get("AiModelsNone") : string.Empty;
        // Read after the wait, so a model typed or picked while the list loaded stays.
        var typed = AiModelBox.Text;
        _loading = true;
        AiModelBox.Items.Clear();
        foreach (var model in models)
        {
            AiModelBox.Items.Add(model);
        }

        AiModelBox.Text = typed;
        _loading = false;
    }

    private void OnAiModelPicked(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading && AiModelBox.SelectedItem is string model)
        {
            SaveModel(model);
        }
    }

    private void OnAiModelTyped(ComboBox sender, ComboBoxTextSubmittedEventArgs args)
    {
        SaveModel(args.Text);
    }

    private void SaveModel(string model)
    {
        if (ChosenProvider is { } provider)
        {
            var trimmed = model.Trim();
            _workbench.UpdateSettings(settings => settings.WithModel(provider, trimmed));
        }
    }
}
