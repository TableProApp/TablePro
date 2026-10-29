using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace TablePro.App.Services;

/// <summary>Dialogs and pickers bound to one window, since a ContentDialog needs its window's XamlRoot.</summary>
public sealed class DialogService(Func<Window> window)
{
    public DialogService(Window window)
        : this(() => window)
    {
    }

    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task<bool> ConfirmAsync(string title, string message, string? primary = null, bool destructive = false, string? detail = null)
    {
        var body = new StackPanel { Spacing = 12, MaxWidth = 560 };
        body.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(detail))
        {
            body.Children.Add(CodeBlock(detail, 260));
        }

        var dialog = Create(title, body, primary ?? Strings.Get("Common/OK"), Strings.Get("Common/Cancel"));
        if (destructive)
        {
            dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        }

        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    public async Task ShowErrorAsync(string title, string message)
    {
        var body = new ScrollViewer { MaxHeight = 360, Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } };
        await ShowAsync(Create(title, body, null, Strings.Get("Common/Close")));
    }

    public async Task<string?> PromptAsync(string title, string label, string initial = "", string? primary = null)
    {
        var box = new TextBox { Header = label, Text = initial, MinWidth = 360 };
        box.Loaded += (_, _) =>
        {
            box.Focus(FocusState.Programmatic);
            box.SelectAll();
        };
        var dialog = Create(title, box, primary ?? Strings.Get("Common/OK"), Strings.Get("Common/Cancel"));
        return await ShowAsync(dialog) == ContentDialogResult.Primary ? box.Text : null;
    }

    /// <summary>
    /// A passphrase in a password box, null when cancelled. With <paramref name="confirm"/> it is typed twice and an
    /// empty value is allowed, which callers read as "no encryption".
    /// </summary>
    public async Task<string?> PromptPassphraseAsync(string title, string message, bool confirm, string? primary = null)
    {
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        var first = new PasswordBox { Header = Strings.Get("Dialogs/Passphrase") };
        var second = new PasswordBox { Header = Strings.Get("Dialogs/ConfirmPassphrase"), Visibility = confirm ? Visibility.Visible : Visibility.Collapsed };
        var mismatch = new InfoBar { Severity = InfoBarSeverity.Error, Message = Strings.Get("Dialogs/PassphrasesDoNotMatch"), IsClosable = false };
        panel.Children.Add(first);
        panel.Children.Add(second);
        panel.Children.Add(mismatch);
        first.Loaded += (_, _) => first.Focus(FocusState.Programmatic);

        var dialog = Create(title, panel, primary ?? Strings.Get("Common/OK"), Strings.Get("Common/Cancel"));
        dialog.PrimaryButtonClick += (_, args) =>
        {
            var mismatched = confirm && first.Password != second.Password;
            mismatch.IsOpen = mismatched;
            args.Cancel = mismatched || (!confirm && first.Password.Length == 0);
        };
        return await ShowAsync(dialog) == ContentDialogResult.Primary ? first.Password : null;
    }

    /// <summary>One field per name, prefilled from <paramref name="defaults"/>; null when cancelled.</summary>
    public async Task<Dictionary<string, string?>?> PromptValuesAsync(string title, string message, IReadOnlyList<string> names, IReadOnlyDictionary<string, string?> defaults)
    {
        var panel = new StackPanel { Spacing = 12, MinWidth = 380 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        var boxes = new List<(string Name, TextBox Box)>();
        foreach (var name in names)
        {
            var box = new TextBox { Header = name, Text = defaults.TryGetValue(name, out var value) ? value ?? "NULL" : string.Empty, PlaceholderText = Strings.Get("Dialogs/ParameterValuePlaceholder") };
            boxes.Add((name, box));
            panel.Children.Add(box);
        }

        if (boxes.Count > 0)
        {
            boxes[0].Box.Loaded += (_, _) => boxes[0].Box.Focus(FocusState.Programmatic);
        }

        var dialog = Create(title, new ScrollViewer { Content = panel, MaxHeight = 420 }, Strings.Get("Common/Run"), Strings.Get("Common/Cancel"));
        if (await ShowAsync(dialog) != ContentDialogResult.Primary)
        {
            return null;
        }

        return boxes.ToDictionary(b => b.Name, b => (string?)b.Box.Text, StringComparer.Ordinal);
    }

    /// <summary>Shows the statements a change will run, the way the macOS app's review sheet does.</summary>
    public async Task<bool> ReviewSqlAsync(string title, IReadOnlyList<string> statements, string? primary = null)
    {
        var body = new StackPanel { Spacing = 12, MinWidth = 520 };
        body.Children.Add(new TextBlock
        {
            Text = Strings.Plural("Dialogs/StatementsWillRun", statements.Count),
            TextWrapping = TextWrapping.Wrap,
        });
        body.Children.Add(CodeBlock(string.Join(";\n\n", statements) + ";", 360));
        return await ShowAsync(Create(title, body, primary ?? Strings.Get("Common/Run"), Strings.Get("Common/Cancel"))) == ContentDialogResult.Primary;
    }

    public async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        // WinUI allows one open ContentDialog per window; queue the rest instead of throwing.
        await _gate.WaitAsync();
        try
        {
            dialog.XamlRoot = window().Content.XamlRoot;
            dialog.RequestedTheme = (window().Content as FrameworkElement)?.RequestedTheme ?? ElementTheme.Default;
            return await dialog.ShowAsync();
        }
        finally
        {
            _gate.Release();
        }
    }

    public ContentDialog Create(string title, object content, string? primary, string close, string? secondary = null)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content,
            CloseButtonText = close,
            DefaultButton = primary is null ? ContentDialogButton.Close : ContentDialogButton.Primary,
            Style = (Style)Application.Current.Resources["DefaultContentDialogStyle"],
        };
        if (primary is not null)
        {
            dialog.PrimaryButtonText = primary;
        }

        if (secondary is not null)
        {
            dialog.SecondaryButtonText = secondary;
        }

        return dialog;
    }

    public async Task<StorageFile?> PickSaveFileAsync(string suggestedName, string typeName, params string[] extensions)
    {
        var picker = new FileSavePicker { SuggestedFileName = suggestedName, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add(typeName, extensions.ToList());
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window()));
        return await picker.PickSaveFileAsync();
    }

    public async Task<StorageFile?> PickOpenFileAsync(params string[] extensions)
    {
        var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, ViewMode = PickerViewMode.List };
        foreach (var extension in extensions.Length == 0 ? ["*"] : extensions)
        {
            picker.FileTypeFilter.Add(extension);
        }

        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(window()));
        return await picker.PickSingleFileAsync();
    }

    public static Border CodeBlock(string text, double maxHeight)
    {
        var block = new TextBlock
        {
            Text = text,
            IsTextSelectionEnabled = true,
            TextWrapping = TextWrapping.Wrap,
            FontSize = 12,
        };
        if (Application.Current.Resources.TryGetValue("CodeFontFamily", out var font) && font is FontFamily family)
        {
            block.FontFamily = family;
        }

        return new Border
        {
            Child = new ScrollViewer { Content = block, MaxHeight = maxHeight, Padding = new Thickness(12) },
            Background = (Brush)Application.Current.Resources["SubtleFillColorSecondaryBrush"],
            BorderBrush = (Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"],
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(6),
        };
    }
}
