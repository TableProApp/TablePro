using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TablePro.App.Model;
using TablePro.App.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TablePro.App.Views;

// One cell's whole value, read only: a picture where the system decodes the bytes, JSON laid out, the text, or a
// binary value's hex. The offset and character columns of a hex dump wait for the core's (roadmap C-11).
internal static class CellValueViewer
{
    private const double ViewerHeight = 400;

    // Wide enough for 64 bytes of hex on a line at the default size.
    private const double ViewerWidth = 720;

    private const int DecodedSide = 2048;

    // A larger picture shows as its hex: the decode size bounds the pixels kept, not the work the codec does to make them.
    private const long MaximumPixels = 64L * 1024 * 1024;

    private enum Mode
    {
        Image,
        Json,
        Text,
        Hex,
    }

    public static async Task ShowAsync(FrameworkElement owner, CellValue value)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(value);
        var picture = value.Bytes is { Length: > 0 } bytes ? await DecodeAsync(bytes).ConfigureAwait(true) : null;
        var json = value.Json();
        var modes = new List<Mode>();
        if (picture is not null)
        {
            modes.Add(Mode.Image);
        }

        if (json is not null)
        {
            modes.Add(Mode.Json);
        }

        modes.Add(value.Bytes is null ? Mode.Text : Mode.Hex);

        var bar = new SelectorBar { Visibility = modes.Count > 1 ? Visibility.Visible : Visibility.Collapsed };
        AutomationProperties.SetName(bar, Strings.Get("ValueViewerModes"));
        AutomationProperties.SetAutomationId(bar, "ValueViewerModes");
        foreach (var mode in modes)
        {
            var item = new SelectorBarItem { Text = Strings.Get("ValueViewer" + mode), Tag = mode };
            AutomationProperties.SetAutomationId(item, "ValueViewer" + mode + "Item");
            bar.Items.Add(item);
        }

        var notice = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Informational, Message = Strings.Get("ValueViewerCut") };
        AutomationProperties.SetAutomationId(notice, "ValueViewerNotice");
        var text = new TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            IsSpellCheckEnabled = false,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New"),
            Height = ViewerHeight,
            // NULL and DEFAULT are no text, so they show as the grid words them, apart from a value that reads so.
            PlaceholderText = value.IsDefault ? Strings.Get("GridDefaultText") : value.IsNull ? Strings.Get("GridMenuNull") : string.Empty,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(text, ScrollBarVisibility.Auto);
        AutomationProperties.SetName(text, value.Column);
        AutomationProperties.SetAutomationId(text, "ValueViewerText");
        // A picture smaller than the viewer shows at its own size, a larger one fits.
        var image = new Image
        {
            Source = picture,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Left,
            MaxWidth = picture?.PixelWidth ?? 0,
            MaxHeight = Math.Min(ViewerHeight, picture?.PixelHeight ?? 0),
        };
        AutomationProperties.SetName(image, value.Column);
        AutomationProperties.SetAutomationId(image, "ValueViewerImage");
        var copy = new Button { Content = Strings.Get("ValueViewerCopy"), IsEnabled = value.CanCopy };
        AutomationProperties.SetAutomationId(copy, "ValueViewerCopy");
        copy.Click += (_, _) => Copy(value, notice);

        void Show(Mode mode)
        {
            var (shown, cut) = mode switch
            {
                Mode.Json => json!.Value,
                Mode.Hex => value.Hex(),
                Mode.Text => value.ShownText(),
                _ => (string.Empty, false),
            };
            image.Visibility = mode == Mode.Image ? Visibility.Visible : Visibility.Collapsed;
            text.Visibility = mode == Mode.Image ? Visibility.Collapsed : Visibility.Visible;
            text.Text = shown;
            notice.Severity = InfoBarSeverity.Informational;
            notice.Message = Strings.Get("ValueViewerCut");
            notice.IsOpen = cut;
        }

        bar.SelectionChanged += (sender, _) =>
        {
            if (sender.SelectedItem?.Tag is Mode mode)
            {
                Show(mode);
            }
        };
        bar.SelectedItem = bar.Items[0];
        Show(modes[0]);

        var top = new Grid { ColumnSpacing = 12 };
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        top.Children.Add(bar);
        Grid.SetColumn(copy, 1);
        copy.VerticalAlignment = VerticalAlignment.Center;
        top.Children.Add(copy);
        var content = new StackPanel { Spacing = 8, Width = ViewerWidth };
        content.Children.Add(top);
        content.Children.Add(notice);
        content.Children.Add(image);
        content.Children.Add(text);

        var dialog = new ContentDialog
        {
            RequestedTheme = owner.ActualTheme,
            Title = Strings.Format("ValueViewerTitle", value.Column),
            Content = content,
            CloseButtonText = Strings.Get("ValueViewerClose"),
            DefaultButton = ContentDialogButton.Close,
        };
        // ContentDialog caps its width at 548 by default, too narrow for a value.
        dialog.Resources["ContentDialogMaxWidth"] = ViewerWidth + 48;
        AutomationProperties.SetAutomationId(dialog, "ValueViewer");
        await WindowDialogs.ShowAsync(dialog, owner).ConfigureAwait(true);
    }

    private static void Copy(CellValue value, InfoBar notice)
    {
        var package = new DataPackage();
        package.SetText(value.CopyText() ?? string.Empty);
        try
        {
            Clipboard.SetContent(package);
            Clipboard.Flush();
        }
        catch (COMException)
        {
            notice.Severity = InfoBarSeverity.Warning;
            notice.Message = Strings.Get("ValueViewerCopyFailed");
            notice.IsOpen = true;
        }
    }

    // Null where no codec on the system reads the bytes as an image, or the image is too large to decode here.
    private static async Task<BitmapImage?> DecodeAsync(byte[] bytes)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(bytes);
            await writer.StoreAsync();
            writer.DetachStream();
        }

        try
        {
            stream.Seek(0);
            var decoder = await BitmapDecoder.CreateAsync(stream);
            var (width, height) = (decoder.PixelWidth, decoder.PixelHeight);
            if (width == 0 || height == 0 || (long)width * height > MaximumPixels)
            {
                return null;
            }

            // A picture larger than the viewer decodes at a size it can show, its longer side bounded, not at every
            // pixel it holds; the other side follows the aspect ratio.
            var bitmap = new BitmapImage();
            if (width >= height && width > DecodedSide)
            {
                bitmap.DecodePixelWidth = DecodedSide;
            }
            else if (height > width && height > DecodedSide)
            {
                bitmap.DecodePixelHeight = DecodedSide;
            }

            stream.Seek(0);
            await bitmap.SetSourceAsync(stream);
            return bitmap;
        }
        catch (Exception error) when (error is COMException or ArgumentException or OutOfMemoryException)
        {
            return null;
        }
    }
}
