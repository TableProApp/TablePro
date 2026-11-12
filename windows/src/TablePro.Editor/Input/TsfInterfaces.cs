using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using TerraFX.Interop.Windows;

namespace TablePro.Editor.Input;

// Declared for the COM source generator so they work under Native AOT; the ones only called come from TerraFX.

[GeneratedComInterface]
[Guid("aa80e80c-2021-11d2-93e0-0060b067b86e")]
internal unsafe partial interface ITfContextOwnerImpl
{
    [PreserveSig]
    int GetACPFromPoint(POINT* point, uint flags, int* acp);

    [PreserveSig]
    int GetTextExt(int start, int end, RECT* rect, BOOL* clipped);

    [PreserveSig]
    int GetScreenExt(RECT* rect);

    [PreserveSig]
    int GetStatus(TS_STATUS* status);

    [PreserveSig]
    int GetWnd(HWND* window);

    [PreserveSig]
    int GetAttribute(Guid* attribute, VARIANT* value);
}

[GeneratedComInterface]
[Guid("5f20aa40-b57a-4f34-96ab-3576f377cc79")]
internal unsafe partial interface ITfContextOwnerCompositionSinkImpl
{
    [PreserveSig]
    int OnStartComposition(nint composition, BOOL* ok);

    [PreserveSig]
    int OnUpdateComposition(nint composition, nint rangeNew);

    [PreserveSig]
    int OnEndComposition(nint composition);
}

[GeneratedComInterface]
[Guid("8127d409-ccd3-4683-967a-b43d5b482bf7")]
internal unsafe partial interface ITfTextEditSinkImpl
{
    [PreserveSig]
    int OnEndEdit(nint context, uint readOnlyCookie, nint editRecord);
}

[GeneratedComInterface]
[Guid("aa80e803-2021-11d2-93e0-0060b067b86e")]
internal partial interface ITfEditSessionImpl
{
    [PreserveSig]
    int DoEditSession(uint editCookie);
}
