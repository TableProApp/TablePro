using Microsoft.UI.Xaml;
using TablePro.App.ConnectionForm;
using TablePro.App.Views;
using WinRT;

// CsWinRT cannot infer the concrete lists passed through the models' interface-typed constructors.
[assembly: GeneratedWinRTExposedExternalType(typeof(List<EngineChoice>))]
[assembly: GeneratedWinRTExposedExternalType(typeof(List<TagChip>))]

// Toolkit 8.2's GridSplitter unboxes GridLength through GetValue (CommunityToolkit/Windows#612).
[assembly: GeneratedWinRTExposedExternalType(typeof(GridLength))]
