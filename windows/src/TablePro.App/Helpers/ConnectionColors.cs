using Microsoft.UI.Xaml.Media;
using TablePro.Core.Connections;
using Windows.UI;

namespace TablePro.App.Helpers;

/// <summary>The connection tags in the hues Windows uses for its own accent palette, readable on light and dark.</summary>
internal static class ConnectionColors
{
    public static Color Color(ConnectionColor tag) => tag switch
    {
        ConnectionColor.Red => Windows.UI.Color.FromArgb(255, 0xE8, 0x11, 0x23),
        ConnectionColor.Orange => Windows.UI.Color.FromArgb(255, 0xF7, 0x63, 0x0C),
        ConnectionColor.Yellow => Windows.UI.Color.FromArgb(255, 0xFF, 0xB9, 0x00),
        ConnectionColor.Green => Windows.UI.Color.FromArgb(255, 0x10, 0x89, 0x3E),
        ConnectionColor.Blue => Windows.UI.Color.FromArgb(255, 0x00, 0x78, 0xD4),
        ConnectionColor.Purple => Windows.UI.Color.FromArgb(255, 0x88, 0x17, 0x98),
        ConnectionColor.Pink => Windows.UI.Color.FromArgb(255, 0xE3, 0x00, 0x8C),
        ConnectionColor.Gray => Windows.UI.Color.FromArgb(255, 0x7A, 0x75, 0x74),
        _ => Microsoft.UI.Colors.Transparent,
    };

    public static SolidColorBrush Brush(ConnectionColor tag) => new(Color(tag));
}
