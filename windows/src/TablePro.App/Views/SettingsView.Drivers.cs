using CommunityToolkit.WinUI.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.Storage.Pickers;
using TablePro.App.Services;
using TablePro.Interop;

namespace TablePro.App.Views;

// Drivers the user adds: a signed library from a file or from TablePro's catalog, loaded from the data folder.
public sealed partial class SettingsView
{
    private IReadOnlyList<InstalledDriver> _installed = [];
    private IReadOnlyList<AvailableDriver>? _available = [];
    private string? _catalog;
    private readonly DriverOperationGate _driverOperations = new();

    // Each card's button, turned off while a driver installs or goes so two never overlap.
    private readonly List<Button> _driverActions = [];

    private Task LoadDriversAsync() => RunDriverOperationAsync(async () =>
    {
        await RefreshInstalledAsync().ConfigureAwait(true);
        try
        {
            _catalog = await DriverCatalog.FetchAsync(CancellationToken.None).ConfigureAwait(true);
            _available = _catalog is null ? [] : DriverPlugins.Available(_catalog);
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or TableProException
            or OperationCanceledException or UnauthorizedAccessException)
        {
            _catalog = null;
            _available = null;
        }

        ShowDrivers();
    });

    private Task RunDriverOperationAsync(Func<Task> operation) =>
        _driverOperations.RunAsync(operation, SetDriversBusy);

    private async Task RefreshInstalledAsync()
    {
        try
        {
            _installed = await _workbench.Core.Drivers.GetInstalledAsync().ConfigureAwait(true);
        }
        catch (TableProException exception)
        {
            ShowDriversMessage(Strings.Error(exception), InfoBarSeverity.Error);
        }

        ShowDrivers();
    }

    private void ShowDrivers()
    {
        _driverActions.Clear();
        InstalledDriversExpander.Items.Clear();
        if (_installed.Count == 0)
        {
            InstalledDriversExpander.Items.Add(Card("NoDrivers", Strings.Get("NoDriversInstalled"), null, null));
        }

        foreach (var driver in _installed)
        {
            var remove = DriverButton("RemoveDriver_" + driver.Id, Strings.Get("RemoveDriver"), Strings.Format("RemoveDriverName", driver.Name));
            remove.Click += async (_, _) => await RemoveDriverAsync(driver).ConfigureAwait(true);
            var description = driver.Error is { } error
                ? Strings.Format("DriverNotLoaded", Strings.Error(error))
                : Strings.Format("DriverVersion", driver.Version);
            InstalledDriversExpander.Items.Add(Card("InstalledDriver_" + driver.Id, driver.Name, description, remove));
        }

        AvailableDriversExpander.Items.Clear();
        if (_available is null || _available.Count == 0 || _catalog is not { } catalog)
        {
            var empty = _available is null ? "DriverCatalogUnavailable" : "DriverCatalogEmpty";
            AvailableDriversExpander.Items.Add(Card("NoAvailableDrivers", Strings.Get(empty), null, null));
            return;
        }

        foreach (var driver in _available)
        {
            var current = _installed.FirstOrDefault(installed => installed.Id == driver.Id && installed.IsLoaded);
            FrameworkElement action;
            if (current?.Version == driver.Version)
            {
                action = new TextBlock { Text = Strings.Get("DriverUpToDate") };
            }
            else
            {
                var label = Strings.Get(current is null ? "InstallDriver" : "UpdateDriver");
                var install = DriverButton("InstallDriver_" + driver.Id, label, Strings.Format("InstallDriverName", label, driver.Name));
                install.Click += async (_, _) => await InstallReleaseAsync(driver, catalog).ConfigureAwait(true);
                action = install;
            }

            AvailableDriversExpander.Items.Add(
                Card("AvailableDriver_" + driver.Id, driver.Name, Strings.Format("DriverVersion", driver.Version), action));
        }
    }

    private Button DriverButton(string automationId, string label, string name)
    {
        var button = new Button { Content = label, IsEnabled = !_driverOperations.IsBusy };
        AutomationProperties.SetAutomationId(button, automationId);
        AutomationProperties.SetName(button, name);
        _driverActions.Add(button);
        return button;
    }

    private static SettingsCard Card(string automationId, string header, string? description, FrameworkElement? action)
    {
        var card = new SettingsCard { Header = header, Description = description, Content = action };
        AutomationProperties.SetAutomationId(card, automationId);
        return card;
    }

    private void SetDriversBusy(bool busy)
    {
        DriversProgress.IsActive = busy;
        InstallDriverFileButton.IsEnabled = !busy;
        foreach (var action in _driverActions)
        {
            action.IsEnabled = !busy;
        }
    }

    private void ShowDriversMessage(string message, InfoBarSeverity severity)
    {
        DriversMessage.Severity = severity;
        DriversMessage.Message = message;
        DriversMessage.IsOpen = false;
        DriversMessage.IsOpen = true;
    }

    private async void OnInstallDriverFile(object sender, RoutedEventArgs e) =>
        await RunDriverOperationAsync(async () =>
        {
            var picker = new FileOpenPicker(XamlRoot.ContentIslandEnvironment.AppWindowId);
            picker.FileTypeFilter.Add(".dll");
            var file = await picker.PickSingleFileAsync();
            if (file is not null)
            {
                await InstallAsync(() => _workbench.Core.Drivers.InstallFileAsync(file.Path)).ConfigureAwait(true);
            }
        }).ConfigureAwait(true);

    private Task InstallReleaseAsync(AvailableDriver driver, string catalog) =>
        RunDriverOperationAsync(() => InstallAsync(async () =>
        {
            var download = await DriverCatalog.DownloadAsync(driver, CancellationToken.None).ConfigureAwait(true);
            try
            {
                return await _workbench.Core.Drivers.InstallReleaseAsync(catalog, driver.Id, download)
                    .ConfigureAwait(true);
            }
            finally
            {
                File.Delete(download);
            }
        }));

    private async Task InstallAsync(Func<Task<InstalledDriver>> install)
    {
        try
        {
            var driver = await install().ConfigureAwait(true);
            ShowDriversMessage(Strings.Format("DriverInstalled", driver.Name, driver.Version), InfoBarSeverity.Success);
        }
        catch (TableProException exception)
        {
            ShowDriversMessage(Strings.Error(exception), InfoBarSeverity.Error);
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or OperationCanceledException
            or UnauthorizedAccessException or InvalidOperationException)
        {
            ShowDriversMessage(Strings.Get("DriverDownloadFailed"), InfoBarSeverity.Error);
        }
        finally
        {
            await RefreshInstalledAsync().ConfigureAwait(true);
        }
    }

    private Task RemoveDriverAsync(InstalledDriver driver) => RunDriverOperationAsync(async () =>
    {
        try
        {
            await _workbench.Core.Drivers.RemoveAsync(driver.Id).ConfigureAwait(true);
            ShowDriversMessage(Strings.Format("DriverRemoved", driver.Name), InfoBarSeverity.Informational);
        }
        catch (TableProException exception)
        {
            ShowDriversMessage(Strings.Error(exception), InfoBarSeverity.Error);
        }
        finally
        {
            await RefreshInstalledAsync().ConfigureAwait(true);
        }
    });
}
