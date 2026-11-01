using System.Globalization;
using System.Runtime.CompilerServices;

namespace TablePro.Tests;

/// <summary>
/// Pins every test assembly to US English before its first test runs. Messages come from .resx resources that follow
/// <see cref="CultureInfo.CurrentUICulture"/>, and numbers follow <see cref="CultureInfo.CurrentCulture"/>, so tests
/// that assert English text would otherwise fail on a machine set to French or Korean. A test that wants another
/// language sets <see cref="CultureInfo.CurrentUICulture"/> itself, which stays with that test's async flow.
/// </summary>
internal static class TestCulture
{
    [ModuleInitializer]
    internal static void PinToEnglish()
    {
        var english = CultureInfo.GetCultureInfo("en-US");
        CultureInfo.DefaultThreadCurrentCulture = english;
        CultureInfo.DefaultThreadCurrentUICulture = english;
        CultureInfo.CurrentCulture = english;
        CultureInfo.CurrentUICulture = english;
    }
}
