using TerraFX.Interop.DirectX;
using TerraFX.Interop.Windows;
using static TerraFX.Interop.DirectX.D2D1_FACTORY_TYPE;
using static TerraFX.Interop.DirectX.D3D_DRIVER_TYPE;
using static TerraFX.Interop.DirectX.D3D11_CREATE_DEVICE_FLAG;
using static TerraFX.Interop.DirectX.DirectX;
using static TerraFX.Interop.Windows.E;

namespace TablePro.Graphics;

// The Basic Render Driver is WARP behind a hardware device type, as on VMs and CI runners without a GPU.
internal sealed unsafe class RenderDevice : IDisposable
{
    // Per thread, so a test on the UI thread does not count the font warm-up's device on a pool thread.
    [ThreadStatic]
    private static int s_created;

    private ID3D11Device* _d3d;
    private IDXGIFactory2* _dxgiFactory;
    private ID2D1Factory1* _d2dFactory;
    private ID2D1Device* _d2dDevice;

    // Multithreaded lets another thread draw with the same device, as the font warm-up does.
    public RenderDevice(bool forceSoftware, bool multithreaded = false)
    {
        var flags = (uint)D3D11_CREATE_DEVICE_BGRA_SUPPORT;
        ID3D11Device* device = null;
        HRESULT created = forceSoftware ? E_FAIL : D3D11CreateDevice(null, D3D_DRIVER_TYPE_HARDWARE, HMODULE.NULL, flags, null, 0,
            D3D11.D3D11_SDK_VERSION, &device, null, null);
        if (created.FAILED)
        {
            NativeCom.Check(D3D11CreateDevice(null, D3D_DRIVER_TYPE_WARP, HMODULE.NULL, flags, null, 0, D3D11.D3D11_SDK_VERSION,
                &device, null, null));
            IsSoftware = true;
        }
        _d3d = device;

        IDXGIDevice* dxgiDevice;
        NativeCom.Check(_d3d->QueryInterface(NativeCom.Iid<IDXGIDevice>(), (void**)&dxgiDevice));
        try
        {
            IDXGIAdapter* adapter;
            NativeCom.Check(dxgiDevice->GetAdapter(&adapter));
            DXGI_ADAPTER_DESC description;
            if (adapter->GetDesc(&description).SUCCEEDED)
            {
                AdapterName = new string((char*)&description.Description);
                IsSoftware |= description.VendorId == 0x1414 && description.DeviceId == 0x8c;
            }
            IDXGIFactory2* factory;
            NativeCom.Check(adapter->GetParent(NativeCom.Iid<IDXGIFactory2>(), (void**)&factory));
            _dxgiFactory = factory;
            adapter->Release();

            var options = new D2D1_FACTORY_OPTIONS();
            ID2D1Factory1* d2dFactory;
            NativeCom.Check(D2D1CreateFactory(multithreaded ? D2D1_FACTORY_TYPE_MULTI_THREADED : D2D1_FACTORY_TYPE_SINGLE_THREADED,
                NativeCom.Iid<ID2D1Factory1>(), &options, (void**)&d2dFactory));
            _d2dFactory = d2dFactory;
            ID2D1Device* d2dDevice;
            NativeCom.Check(_d2dFactory->CreateDevice(dxgiDevice, &d2dDevice));
            _d2dDevice = d2dDevice;
        }
        finally
        {
            dxgiDevice->Release();
        }
        s_created++;
    }

    internal static int CreatedOnThisThread => s_created;

    // A driver update or a TDR removes the device while nothing draws; what is made on it next fails.
    public bool IsLost => _d3d is null || SimulatedLoss || _d3d->GetDeviceRemovedReason().FAILED;

    // For the tests, as the grid's FailNextDraw.
    internal bool SimulatedLoss { get; set; }

    public bool IsSoftware { get; }

    public string AdapterName { get; } = string.Empty;

    public ID3D11Device* Direct3D => _d3d;

    public IDXGIFactory2* DxgiFactory => _dxgiFactory;

    public ID2D1Device* Direct2D => _d2dDevice;

    public void Dispose()
    {
        NativeCom.Release(ref _d2dDevice);
        NativeCom.Release(ref _d2dFactory);
        NativeCom.Release(ref _dxgiFactory);
        NativeCom.Release(ref _d3d);
    }
}
