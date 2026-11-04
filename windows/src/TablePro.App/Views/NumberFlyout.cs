using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TablePro.App.Services;
using Windows.Globalization.NumberFormatting;
using Windows.System;

namespace TablePro.App.Views;

// A number asked for in place, as the macOS pager asks in a popover. Built for each use: a flyout keeps the
// window it first opened in (microsoft/microsoft-ui-xaml#10207), and a tab can move to another window.
internal static class NumberFlyout
{
    public static Flyout Create(NumberRequest request, Action<long> submit)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(submit);
        var box = new NumberBox
        {
            Header = request.Caption,
            Description = Strings.Format("NumberRange", 1, request.Maximum),
            Minimum = 1,
            Maximum = request.Maximum,
            Value = request.Value,
            SmallChange = 1,
            LargeChange = 10,
            MinWidth = 200,
            SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact,
            // The box keeps a typed number inside the range, which is the bound the count gives.
            ValidationMode = NumberBoxValidationMode.InvalidInputOverwritten,
            NumberFormatter = new DecimalFormatter { FractionDigits = 0, IsGrouped = true },
        };
        AutomationProperties.SetAutomationId(box, request.BoxId);
        var button = new Button
        {
            Content = request.Action,
            HorizontalAlignment = HorizontalAlignment.Right,
            Style = (Style)Application.Current.Resources["AccentButtonStyle"],
        };
        AutomationProperties.SetAutomationId(button, request.ButtonId);
        var flyout = new Flyout
        {
            Content = new StackPanel { Spacing = 12, Children = { box, button } },
        };

        void Submit()
        {
            if (!double.IsNaN(box.Value))
            {
                flyout.Hide();
                submit((long)Math.Round(box.Value));
            }
        }

        button.Click += (_, _) => Submit();
        // NumberBox takes Enter itself to commit the text, so the handler asks for handled events too.
        box.AddHandler(
            UIElement.KeyUpEvent,
            new KeyEventHandler((_, args) =>
            {
                if (args.Key == VirtualKey.Enter)
                {
                    Submit();
                }
            }),
            handledEventsToo: true);
        flyout.Opened += (_, _) => box.Focus(FocusState.Programmatic);
        return flyout;
    }
}

internal sealed record NumberRequest(string Caption, long Value, long Maximum, string Action, string BoxId, string ButtonId);
