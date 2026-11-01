using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace TablePro.App.Converters;

/// <summary>Lets a string property bind two-way to a selector's object-typed SelectedItem.</summary>
public sealed partial class ObjectToStringConverter : IValueConverter
{
    public object? Convert(object? value, Type targetType, object? parameter, string language) => value;

    public object? ConvertBack(object? value, Type targetType, object? parameter, string language) => value as string;
}

public sealed partial class NotNullConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language) =>
        value is string s ? !string.IsNullOrEmpty(s) : value is not null;

    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

public sealed partial class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object? value, Type targetType, object? parameter, string language) =>
        (value is true) ^ Invert ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}
