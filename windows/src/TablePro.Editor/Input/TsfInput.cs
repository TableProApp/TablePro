// Ported from Windows Terminal's src/tsf/Implementation.cpp (https://github.com/microsoft/terminal),
// Copyright (c) Microsoft Corporation, licensed under the MIT license.

using System.Runtime.InteropServices;
using System.Runtime.InteropServices.Marshalling;
using TablePro.Editor.Rendering;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.Windows.E;
using static TerraFX.Interop.Windows.S;
using static TerraFX.Interop.Windows.Windows;

namespace TablePro.Editor.Input;

public enum CompositionUnderline
{
    None,
    Solid,
    Dotted,
    Dashed,
    Squiggle,
}

// A stretch of the text being composed and how the IME wants it marked.
public readonly record struct CompositionRun(int Start, int Length, CompositionUnderline Underline, bool Bold);

internal interface ITsfHost
{
    HWND Window { get; }

    // Screen pixels of the caret, where the IME puts its candidate list.
    RECT CaretScreenRect();

    // Screen pixels of the editor, where the touch keyboard looks.
    RECT ViewScreenRect();

    void Commit(string text);

    // The text being composed, shown at the caret but not yet in the document. Empty when composition ends.
    void ShowComposition(string text, int caret, IReadOnlyList<CompositionRun> runs);
}

// The editor's TSF client, done as Windows Terminal does it: one context whose text store TSF owns
// (ITfContextOwner), holding only the text being composed. Finished text moves into the document as typing and
// leaves the context, so the IME never reads the 5 MB document and composition never reaches the undo history.
// CoreTextEditContext is not used: its context is not transitory (windows/docs/decisions/0002-sql-editor-control.md,
// Input).
internal sealed unsafe partial class TsfInput : IDisposable
{
    private static readonly Guid ThreadMgrClsid = new("529a9e6b-6587-4f23-ab9e-9c7d683e3c50");
    private static readonly Guid CategoryMgrClsid = new("a4b544a1-438d-4b41-9325-869523e2d6c7");
    private static readonly Guid DisplayAttributeMgrClsid = new("3ce74de4-53d3-4d74-8b83-431b3828ba53");
    private static readonly Guid PropComposing = new("e12ac060-af15-11d2-afc5-00105a2799b5");
    private static readonly Guid PropAttribute = new("34b45670-7526-11d2-a147-00105a2799b5");
    private static readonly StrategyBasedComWrappers Wrappers = new();

    private readonly ITsfHost _host;
    private readonly Sink _sink;
    private readonly EditSession _session;
    private ITfThreadMgrEx* _threadMgr;
    private ITfDocumentMgr* _documentMgr;
    private ITfContext* _context;
    private ITfSource* _source;
    private ITfContextOwnerCompositionServices* _services;
    private ITfCategoryMgr* _categories;
    private ITfDisplayAttributeMgr* _attributes;
    private nint _sinkUnknown;
    private nint _sessionPointer;
    private uint _clientId;
    private uint _ownerCookie = TF.TF_INVALID_COOKIE;
    private uint _editCookie = TF.TF_INVALID_COOKIE;
    private int _compositions;
    private bool _sessionPending;
    private HWND _window;

    private TsfInput(ITsfHost host)
    {
        _host = host;
        _sink = new Sink(this);
        _session = new EditSession(this);
    }

    public bool HasActiveComposition => _compositions > 0;

    public string? FailureReason { get; private set; }

    // Null when TSF is unavailable; the editor then takes plain key input only.
    public static TsfInput? Create(ITsfHost host)
    {
        var input = new TsfInput(host);
        try
        {
            input.Initialize();
            return input;
        }
        catch (Exception e) when (e is COMException or InvalidCastException or ArgumentException or UnauthorizedAccessException)
        {
            input.Dispose();
            return null;
        }
    }

    public void Focus()
    {
        _window = FindWindowOfActiveTsf();
        var focused = _threadMgr->SetFocus(_documentMgr);
        FailureReason = focused.FAILED ? $"SetFocus 0x{focused.Value:X8}" : FailureReason;
    }

    public void Unfocus()
    {
        _host.ShowComposition(string.Empty, 0, []);
        if (_compositions > 0 && _services is not null)
        {
            _services->TerminateComposition(null);
        }
    }

    // A composition that just ended still has its text queued in TSF. The key that ended it must not reach the
    // editor before that text does, so key handling flushes it first (Terminal GH#20244).
    public void FlushPendingComposition()
    {
        if (_compositions > 0 || !_sessionPending || _context is null)
        {
            return;
        }
        HRESULT result;
        _context->RequestEditSession(_clientId, (ITfEditSession*)_sessionPointer, TF.TF_ES_READWRITE | TF.TF_ES_SYNC, &result);
    }

    public void Dispose()
    {
        if (_source is not null)
        {
            if (_editCookie != TF.TF_INVALID_COOKIE)
            {
                _source->UnadviseSink(_editCookie);
            }
            if (_ownerCookie != TF.TF_INVALID_COOKIE)
            {
                _source->UnadviseSink(_ownerCookie);
            }
        }
        if (_documentMgr is not null)
        {
            _documentMgr->Pop(TF.TF_POPF_ALL);
        }
        if (_threadMgr is not null)
        {
            _threadMgr->Deactivate();
        }
        NativeCom.Release(ref _services);
        NativeCom.Release(ref _source);
        NativeCom.Release(ref _context);
        NativeCom.Release(ref _documentMgr);
        NativeCom.Release(ref _threadMgr);
        NativeCom.Release(ref _categories);
        NativeCom.Release(ref _attributes);
        if (_sessionPointer != 0)
        {
            Marshal.Release(_sessionPointer);
            _sessionPointer = 0;
        }
        if (_sinkUnknown != 0)
        {
            Marshal.Release(_sinkUnknown);
            _sinkUnknown = 0;
        }
    }

    private void Initialize()
    {
        _categories = Create<ITfCategoryMgr>(CategoryMgrClsid);
        _attributes = Create<ITfDisplayAttributeMgr>(DisplayAttributeMgrClsid);
        // ITfThreadMgr is one per thread; creating it again returns that one.
        _threadMgr = Create<ITfThreadMgrEx>(ThreadMgrClsid);

        // Terminal's flags. TF_TMAE_CONSOLE keeps Korean IMEs from leaving interim characters, which this editor
        // cannot take back once they reach the document.
        uint clientId;
        NativeCom.Check(_threadMgr->ActivateEx(&clientId,
            TF.TF_TMAE_NOACTIVATETIP | TF.TF_TMAE_NOACTIVATEKEYBOARDLAYOUT | TF.TF_TMAE_CONSOLE));
        _clientId = clientId;
        ITfDocumentMgr* documentMgr;
        NativeCom.Check(_threadMgr->CreateDocumentMgr(&documentMgr));
        _documentMgr = documentMgr;

        _sinkUnknown = Wrappers.GetOrCreateComInterfaceForObject(_sink, CreateComInterfaceFlags.None);
        _sessionPointer = QueryInterface(Wrappers.GetOrCreateComInterfaceForObject(_session, CreateComInterfaceFlags.None),
            typeof(ITfEditSessionImpl).GUID, release: true);
        var compositionSink = QueryInterface(_sinkUnknown, typeof(ITfContextOwnerCompositionSinkImpl).GUID, release: false);
        try
        {
            ITfContext* context;
            uint textStoreCookie;
            NativeCom.Check(_documentMgr->CreateContext(_clientId, 0, (IUnknown*)compositionSink, &context, &textStoreCookie));
            _context = context;
        }
        finally
        {
            Marshal.Release(compositionSink);
        }
        ITfContextOwnerCompositionServices* services;
        if (_context->QueryInterface(NativeCom.Iid<ITfContextOwnerCompositionServices>(), (void**)&services).SUCCEEDED)
        {
            _services = services;
        }
        ITfSource* source;
        NativeCom.Check(_context->QueryInterface(NativeCom.Iid<ITfSource>(), (void**)&source));
        _source = source;
        uint cookie;
        var ownerIid = typeof(ITfContextOwnerImpl).GUID;
        NativeCom.Check(_source->AdviseSink(&ownerIid, (IUnknown*)_sinkUnknown, &cookie));
        _ownerCookie = cookie;
        var editIid = typeof(ITfTextEditSinkImpl).GUID;
        NativeCom.Check(_source->AdviseSink(&editIid, (IUnknown*)_sinkUnknown, &cookie));
        _editCookie = cookie;
        NativeCom.Check(_documentMgr->Push(_context));
    }

    // WinUI's own TSF runs in its input site window. Taking focus from it needs that window, which the context
    // TSF made active last reports.
    private HWND FindWindowOfActiveTsf()
    {
        IEnumTfDocumentMgrs* documents = null;
        ITfDocumentMgr* document = null;
        ITfContext* context = null;
        ITfContextView* view = null;
        try
        {
            if (_threadMgr->EnumDocumentMgrs(&documents).FAILED || documents->Next(1, &document, null) != S_OK
                || document->GetTop(&context).FAILED || context is null || context->GetActiveView(&view).FAILED)
            {
                return _host.Window;
            }
            HWND window;
            return view->GetWnd(&window).SUCCEEDED && window != HWND.NULL ? window : _host.Window;
        }
        finally
        {
            NativeCom.Release(ref view);
            NativeCom.Release(ref context);
            NativeCom.Release(ref document);
            NativeCom.Release(ref documents);
        }
    }

    // Each update reads the context as it is then, so an extra queued one does no harm, and none is skipped.
    private void RequestUpdate()
    {
        _sessionPending = true;
        HRESULT result;
        // An edit session asked for from inside one must be asynchronous.
        if (_context->RequestEditSession(_clientId, (ITfEditSession*)_sessionPointer, TF.TF_ES_READWRITE | TF.TF_ES_ASYNC, &result).FAILED)
        {
            _sessionPending = false;
        }
    }

    // Reads the context: text no longer composing at its start is finished and goes to the document; the rest is
    // the composition, shown at the caret with the IME's marks.
    private void UpdateComposition(uint cookie)
    {
        _sessionPending = false;
        ITfRange* full = null;
        ITfReadOnlyProperty* properties = null;
        IEnumTfRanges* ranges = null;
        var finished = new System.Text.StringBuilder();
        var composing = new System.Text.StringBuilder();
        var runs = new List<CompositionRun>();
        try
        {
            NativeCom.Check(_context->GetStart(cookie, &full));
            int fullLength;
            NativeCom.Check(full->ShiftEnd(cookie, int.MaxValue, &fullLength, null));
            var composingGuid = PropComposing;
            var attributeGuid = PropAttribute;
            var guids = stackalloc Guid*[2] { &composingGuid, &attributeGuid };
            NativeCom.Check(_context->TrackProperties(guids, 2, null, 0, &properties));
            NativeCom.Check(properties->EnumRanges(cookie, &ranges, full));

            var seenComposing = false;
            var batch = stackalloc ITfRange*[8];
            var buffer = stackalloc char[128];
            HRESULT next;
            do
            {
                uint count;
                next = ranges->Next(8, batch, &count);
                for (var i = 0; i < count; i++)
                {
                    var range = batch[i];
                    try
                    {
                        var (isComposing, atom) = ReadProperties(properties, cookie, range);
                        var active = isComposing || seenComposing;
                        var target = active ? composing : finished;
                        var length = 0;
                        while (true)
                        {
                            uint read;
                            NativeCom.Check(range->GetText(cookie, TF.TF_TF_MOVESTART, buffer, 128, &read));
                            target.Append(buffer, (int)read);
                            length += (int)read;
                            if (read < 128)
                            {
                                break;
                            }
                        }
                        if (active)
                        {
                            var (underline, bold) = Marks(atom);
                            runs.Add(new CompositionRun(composing.Length - length, length, underline, bold));
                        }
                        seenComposing |= isComposing;
                    }
                    finally
                    {
                        range->Release();
                    }
                }
            }
            while (next == S_OK);

            var caret = CaretInContext(cookie) - finished.Length;
            caret = Math.Clamp(caret, 0, composing.Length);
            if (finished.Length > 0)
            {
                ITfRange* done;
                NativeCom.Check(_context->GetStart(cookie, &done));
                int moved;
                done->ShiftEnd(cookie, finished.Length, &moved, null);
                done->SetText(cookie, 0, null, 0);
                done->Release();
            }
            _host.ShowComposition(composing.ToString(), caret, runs);
            if (finished.Length > 0)
            {
                _host.Commit(finished.ToString());
            }
        }
        finally
        {
            NativeCom.Release(ref ranges);
            NativeCom.Release(ref properties);
            NativeCom.Release(ref full);
        }
    }

    private static (bool Composing, uint Atom) ReadProperties(ITfReadOnlyProperty* properties, uint cookie, ITfRange* range)
    {
        VARIANT value;
        NativeCom.Check(properties->GetValue(cookie, range, &value));
        try
        {
            if (value.vt != (ushort)VARENUM.VT_UNKNOWN || value.punkVal is null)
            {
                return (false, TF.TF_INVALID_GUIDATOM);
            }
            IEnumTfPropertyValue* values;
            if (value.punkVal->QueryInterface(NativeCom.Iid<IEnumTfPropertyValue>(), (void**)&values).FAILED)
            {
                return (false, TF.TF_INVALID_GUIDATOM);
            }
            var composing = false;
            var atom = TF.TF_INVALID_GUIDATOM;
            var pair = stackalloc TF_PROPERTYVAL[2];
            uint fetched;
            values->Next(2, pair, &fetched);
            for (var i = 0; i < fetched; i++)
            {
                if (pair[i].guidId == PropComposing)
                {
                    composing = pair[i].varValue.vt == (ushort)VARENUM.VT_I4 && pair[i].varValue.lVal != 0;
                }
                else if (pair[i].guidId == PropAttribute)
                {
                    atom = pair[i].varValue.vt == (ushort)VARENUM.VT_I4 ? (uint)pair[i].varValue.lVal : TF.TF_INVALID_GUIDATOM;
                }
                VariantClear(&pair[i].varValue);
            }
            values->Release();
            return (composing, atom);
        }
        finally
        {
            VariantClear(&value);
        }
    }

    private int CaretInContext(uint cookie)
    {
        TF_SELECTION selection;
        uint count;
        if (_context->GetSelection(cookie, TF.TF_DEFAULT_SELECTION, 1, &selection, &count).FAILED || count != 1)
        {
            return int.MaxValue;
        }
        ITfRange* start = null;
        try
        {
            NativeCom.Check(_context->GetStart(cookie, &start));
            var halt = new TF_HALTCOND
            {
                pHaltRange = selection.range,
                aHaltPos = selection.style.ase == TfActiveSelEnd.TF_AE_START ? TfAnchor.TF_ANCHOR_START : TfAnchor.TF_ANCHOR_END,
            };
            int position;
            NativeCom.Check(start->ShiftEnd(cookie, int.MaxValue, &position, &halt));
            return position;
        }
        finally
        {
            NativeCom.Release(ref start);
            selection.range->Release();
        }
    }

    // Telex gives no attribute; Terminal marks that with a dashed underline, as Firefox did.
    private (CompositionUnderline Underline, bool Bold) Marks(uint atom)
    {
        if (atom == TF.TF_INVALID_GUIDATOM)
        {
            return (CompositionUnderline.Dashed, false);
        }
        Guid guid;
        if (_categories->GetGUID(atom, &guid).FAILED)
        {
            return (CompositionUnderline.Solid, false);
        }
        ITfDisplayAttributeInfo* info;
        if (_attributes->GetDisplayAttributeInfo(&guid, &info, null).FAILED)
        {
            return (CompositionUnderline.Solid, false);
        }
        TF_DISPLAYATTRIBUTE attribute;
        var read = info->GetAttributeInfo(&attribute);
        info->Release();
        if (read.FAILED)
        {
            return (CompositionUnderline.Solid, false);
        }
        var underline = attribute.lsStyle switch
        {
            TF_DA_LINESTYLE.TF_LS_SOLID => CompositionUnderline.Solid,
            TF_DA_LINESTYLE.TF_LS_DOT => CompositionUnderline.Dotted,
            TF_DA_LINESTYLE.TF_LS_DASH => CompositionUnderline.Dashed,
            TF_DA_LINESTYLE.TF_LS_SQUIGGLE => CompositionUnderline.Squiggle,
            _ => CompositionUnderline.None,
        };
        return (underline, attribute.fBoldLine);
    }

    private static T* Create<T>(Guid clsid)
        where T : unmanaged, TerraFX.Interop.INativeGuid
    {
        T* instance;
        NativeCom.Check(CoCreateInstance(&clsid, null, (uint)CLSCTX.CLSCTX_INPROC_SERVER, NativeCom.Iid<T>(), (void**)&instance));
        return instance;
    }

    private static nint QueryInterface(nint unknown, Guid iid, bool release)
    {
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(unknown, in iid, out var result));
        if (release)
        {
            Marshal.Release(unknown);
        }
        return result;
    }

    [GeneratedComClass]
    private sealed partial class Sink(TsfInput owner) : ITfContextOwnerImpl, ITfContextOwnerCompositionSinkImpl, ITfTextEditSinkImpl
    {
        public int GetACPFromPoint(POINT* point, uint flags, int* acp) => E_NOTIMPL;

        public int GetTextExt(int start, int end, RECT* rect, BOOL* clipped)
        {
            if (rect is not null)
            {
                *rect = owner._host.CaretScreenRect();
            }
            if (clipped is not null)
            {
                *clipped = BOOL.FALSE;
            }
            return S_OK;
        }

        public int GetScreenExt(RECT* rect)
        {
            if (rect is not null)
            {
                *rect = owner._host.ViewScreenRect();
            }
            return S_OK;
        }

        // Transitory: once composition ends TSF keeps nothing of it, which is what this client gives it.
        public int GetStatus(TS_STATUS* status)
        {
            if (status is not null)
            {
                status->dwDynamicFlags = 0;
                status->dwStaticFlags = TS.TS_SS_TRANSITORY | TS.TS_SS_NOHIDDENTEXT;
            }
            return S_OK;
        }

        public int GetWnd(HWND* window)
        {
            *window = owner._window != HWND.NULL ? owner._window : owner._host.Window;
            return S_OK;
        }

        public int GetAttribute(Guid* attribute, VARIANT* value)
        {
            value->vt = (ushort)VARENUM.VT_EMPTY;
            return S_OK;
        }

        public int OnStartComposition(nint composition, BOOL* ok)
        {
            owner._compositions++;
            *ok = BOOL.TRUE;
            return S_OK;
        }

        public int OnUpdateComposition(nint composition, nint rangeNew) => S_OK;

        public int OnEndComposition(nint composition)
        {
            if (owner._compositions <= 0)
            {
                return E_FAIL;
            }
            owner._compositions--;
            if (owner._compositions == 0)
            {
                owner.RequestUpdate();
            }
            return S_OK;
        }

        public int OnEndEdit(nint context, uint readOnlyCookie, nint editRecord)
        {
            if (owner._compositions == 1)
            {
                owner.RequestUpdate();
            }
            return S_OK;
        }
    }

    [GeneratedComClass]
    private sealed partial class EditSession(TsfInput owner) : ITfEditSessionImpl
    {
        public int DoEditSession(uint editCookie)
        {
            try
            {
                owner.UpdateComposition(editCookie);
                return S_OK;
            }
            catch (COMException exception)
            {
                owner.FailureReason = exception.Message;
                return exception.HResult;
            }
        }
    }
}
