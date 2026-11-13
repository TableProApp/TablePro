using Microsoft.Windows.AppLifecycle;
using TablePro.App.Model;
using Windows.ApplicationModel.Activation;

namespace TablePro.App.Services;

// A packaged launch carries the tablepro:// link as a protocol activation, the execution alias as an argument.
internal static class ActivationLink
{
    // Read on the thread that raised the activation, before it is handed to the UI thread.
    public static string? Of(AppActivationArguments activation)
    {
        ArgumentNullException.ThrowIfNull(activation);
        return activation.Kind switch
        {
            ExtendedActivationKind.Protocol when activation.Data is IProtocolActivatedEventArgs protocol =>
                protocol.Uri?.OriginalString,
            ExtendedActivationKind.Launch when activation.Data is ILaunchActivatedEventArgs launch =>
                InArguments(launch.Arguments),
            _ => null,
        };
    }

    // A first launch reads its own command line, which the activation's arguments may leave out.
    public static string? OfLaunch(AppActivationArguments activation) =>
        Of(activation) ?? SharedLinkOpen.LinkIn(Environment.GetCommandLineArgs().Skip(1));

    private static string? InArguments(string? arguments) =>
        SharedLinkOpen.LinkIn((arguments ?? string.Empty).Split(' ', StringSplitOptions.RemoveEmptyEntries));
}
