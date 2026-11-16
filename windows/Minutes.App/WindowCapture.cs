using System.Runtime.InteropServices;
using Windows.Graphics.Capture;

namespace Minutes.App;

internal static class WindowCapture
{
    private static readonly Dictionary<nint, long> seen = [];
    private static long sequence;
    public static void Observe()
    {
        var live = new HashSet<nint>(); var observation = ++sequence;
        EnumWindows((window, _) => { live.Add(window); if (!seen.ContainsKey(window)) seen[window] = observation; return true; }, 0);
        foreach (var gone in seen.Keys.Where(w => !live.Contains(w)).ToArray()) seen.Remove(gone);
    }
    public static GraphicsCaptureItem Create(nint owner, uint? processId)
    {
        Observe(); var candidates = new List<nint>();
        if (processId != null) EnumWindows((window, _) =>
        {
            GetWindowThreadProcessId(window, out var pid);
            if (pid == processId && IsWindowVisible(window) && GetWindowRect(window, out var rect) && rect.Right - rect.Left >= 320 && rect.Bottom - rect.Top >= 200) candidates.Add(window);
            return true;
        }, 0);
        var target = candidates.OrderByDescending(w => seen.GetValueOrDefault(w)).FirstOrDefault();
        var interopID = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"); var itemID = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
        nint name = 0, factory = 0, item = 0; object? wrapper = null;
        try
        {
            const string runtime = "Windows.Graphics.Capture.GraphicsCaptureItem";
            Marshal.ThrowExceptionForHR(WindowsCreateString(runtime, runtime.Length, out name)); Marshal.ThrowExceptionForHR(RoGetActivationFactory(name, ref interopID, out factory));
            wrapper = Marshal.GetObjectForIUnknown(factory); var interop = (ICaptureInterop)wrapper;
            Marshal.ThrowExceptionForHR(target != 0 ? interop.CreateForWindow(target, ref itemID, out item) : interop.CreateForMonitor(MonitorFromWindow(owner, 2), ref itemID, out item));
            return WinRT.MarshalInterface<GraphicsCaptureItem>.FromAbi(item);
        }
        finally { if (item != 0) Marshal.Release(item); if (wrapper != null && Marshal.IsComObject(wrapper)) Marshal.ReleaseComObject(wrapper); if (factory != 0) Marshal.Release(factory); if (name != 0) WindowsDeleteString(name); }
    }
    [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ICaptureInterop
    {
        [PreserveSig] int CreateForWindow(nint window, ref Guid iid, out nint item);
        [PreserveSig] int CreateForMonitor(nint monitor, ref Guid iid, out nint item);
    }
    private delegate bool WindowEnum(nint window, nint data);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(WindowEnum callback, nint data);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] private static extern int WindowsCreateString(string value, int length, out nint result);
    [DllImport("combase.dll")] private static extern int WindowsDeleteString(nint value);
    [DllImport("combase.dll")] private static extern int RoGetActivationFactory(nint runtime, ref Guid iid, out nint factory);
}
