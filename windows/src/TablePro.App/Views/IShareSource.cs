using TablePro.Interop;

namespace TablePro.App.Views;

// A tab whose menus offer a share; the workspace that holds it opens the sheet.
internal interface IShareSource
{
    event EventHandler<ShareKind>? ShareRequested;
}
