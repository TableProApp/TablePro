using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TablePro.Interop;

namespace TablePro.App.Services;

internal sealed class CredentialDialogs(FrameworkElement owner) : ICredentialPrompter
{
    private static readonly SemaphoreSlim Showing = new(1);

    public Task<CredentialAnswer?> PromptAsync(CredentialPrompt prompt, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<CredentialAnswer?>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!owner.DispatcherQueue.TryEnqueue(async () =>
        {
            try
            {
                completion.TrySetResult(await ShowAsync(prompt, cancellationToken).ConfigureAwait(true));
            }
            catch (OperationCanceledException)
            {
                completion.TrySetCanceled(cancellationToken);
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        }))
        {
            completion.TrySetResult(null);
        }

        return completion.Task.WaitAsync(cancellationToken);
    }

    internal async Task<bool> RecoverHostKeyAsync(
        TableProCore core, SavedConnection connection, HostKeyFailure failure, CancellationToken cancellationToken)
    {
        if (!failure.TrustAllowed)
        {
            return false;
        }

        var prompt = new CredentialPrompt(new PromptPurpose.SshConfirmation(
            Strings.Format("SshChangedKeyMessage", failure.Host, failure.Algorithm, failure.Fingerprint)),
            failure.Host, [], false);
        var answer = await ShowAsync(prompt, cancellationToken, "SshChangedKeyTitle", "SshForgetKeyButton").ConfigureAwait(true);
        if (answer is null)
        {
            return false;
        }

        cancellationToken.ThrowIfCancellationRequested();
        await core.ForgetChangedHostKeyAsync(connection, failure).ConfigureAwait(true);
        return true;
    }

    private async Task<CredentialAnswer?> ShowAsync(
        CredentialPrompt prompt,
        CancellationToken cancellationToken,
        string? title = null,
        string? primaryButton = null)
    {
        await Showing.WaitAsync(cancellationToken).ConfigureAwait(true);
        try
        {
            if (owner.XamlRoot is null)
            {
                var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                void OnLoaded(object sender, RoutedEventArgs args) => loaded.TrySetResult();
                owner.Loaded += OnLoaded;
                try
                {
                    await loaded.Task.WaitAsync(cancellationToken).ConfigureAwait(true);
                }
                finally
                {
                    owner.Loaded -= OnLoaded;
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            var content = new StackPanel { Spacing = 12 };
            var message = new TextBlock
            {
                Text = Message(prompt),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            AutomationProperties.SetAutomationId(message, prompt.Purpose is PromptPurpose.SshHostKey
                ? "SshHostKeyDetails" : "CredentialPromptMessage");
            content.Children.Add(message);
            var values = new List<Func<string>>();
            for (var index = 0; index < prompt.Fields.Count; index++)
            {
                var field = prompt.Fields[index];
                Control input;
                if (field.Secret)
                {
                    var box = new PasswordBox { Header = FieldLabel(prompt, field) };
                    values.Add(() => box.Password);
                    input = box;
                }
                else
                {
                    var box = new TextBox { Header = FieldLabel(prompt, field) };
                    values.Add(() => box.Text);
                    input = box;
                }

                AutomationProperties.SetAutomationId(input, index == 0 ? "SecretBox" : "PromptField_" + index);
                content.Children.Add(input);
                if (index == 0)
                {
                    input.Loaded += (_, _) => input.Focus(FocusState.Programmatic);
                }
            }

            var remember = new CheckBox { Content = Strings.Get("SaveSecret") };
            AutomationProperties.SetAutomationId(remember, "SaveSecretBox");
            if (prompt.OfferRemember)
            {
                content.Children.Add(remember);
            }

            var trust = prompt.Purpose is PromptPurpose.SshHostKey or PromptPurpose.SshConfirmation;
            var dialog = new ContentDialog
            {
                XamlRoot = owner.XamlRoot,
                RequestedTheme = owner.ActualTheme,
                Title = Strings.Get(title ?? (trust ? "SshTrustTitle" : "SecretRequiredTitle")),
                Content = new ScrollViewer { Content = content, MaxHeight = 480 },
                PrimaryButtonText = Strings.Get(primaryButton ?? (trust ? "SshTrustButton" : "ConnectButtonText")),
                CloseButtonText = Strings.Get("Cancel"),
                DefaultButton = trust ? ContentDialogButton.Close : ContentDialogButton.Primary,
            };
            AutomationProperties.SetAutomationId(dialog, "CredentialDialog");
            var shown = dialog.ShowAsync();
            using var registration = cancellationToken.Register(() => owner.DispatcherQueue.TryEnqueue(dialog.Hide));
            var result = await shown;
            cancellationToken.ThrowIfCancellationRequested();
            return result == ContentDialogResult.Primary
                ? new CredentialAnswer([.. values.Select(read => read())], prompt.OfferRemember && remember.IsChecked == true)
                : null;
        }
        catch (COMException)
        {
            // A different app dialog may own this UI thread; declining lets the connection be retried safely.
            return null;
        }
        finally
        {
            Showing.Release();
        }
    }

    private static string FieldLabel(CredentialPrompt prompt, PromptField field) => prompt.Purpose switch
    {
        PromptPurpose.DatabasePassword => Strings.Get("Secret_DatabasePassword"),
        PromptPurpose.SshPassword => Strings.Get("Secret_SshPassword"),
        PromptPurpose.SshPassphrase => Strings.Get("Secret_SshPassphrase"),
        _ => field.Label,
    };

    private static string Message(CredentialPrompt prompt) => prompt.Purpose switch
    {
        PromptPurpose.SshHostKey host => Strings.Format("SshTrustMessage", host.Host, host.Algorithm, host.Fingerprint),
        PromptPurpose.SshPassphrase key => Strings.Format("SshPassphraseMessage", key.Path, prompt.Target),
        PromptPurpose.SshKeyboardInteractive keyboard => string.Join(Environment.NewLine,
            new[] { prompt.Target, keyboard.Name, keyboard.Instructions }.Where(value => value.Length > 0)),
        PromptPurpose.SshConfirmation confirmation => confirmation.Text,
        _ => Strings.Format("SecretRequiredMessage", prompt.Target),
    };
}
