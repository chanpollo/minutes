using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.UI.Xaml;
using Minutes.Core;

namespace Minutes.App;

internal sealed class DesktopIntegration : IDisposable
{
    private readonly nint hwnd;
    private readonly SubclassProc callback;
    private readonly Action show, record, stop, note, settings;
    private bool exiting;
    private readonly Func<bool> canQuit;
    private readonly Action<string> chooseMode;
    private NotifyIconData icon;
    public DesktopIntegration(Window window, Action show, Action record, Action stop, Action note, Action settings, Func<bool> canQuit, Action<string> chooseMode)
    {
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window); this.show = show; this.record = record; this.stop = stop; this.note = note; this.settings = settings; this.canQuit = canQuit; this.chooseMode = chooseMode;
        callback = OnMessage; if (!SetWindowSubclass(hwnd, callback, 1, 0)) throw new System.ComponentModel.Win32Exception();
        RegisterHotKey(hwnd, 1, 0x0001 | 0x0002 | 0x4000, 0x52);
        icon = new NotifyIconData { Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = hwnd, Id = 1, Flags = 1 | 2 | 4, CallbackMessage = 0x8001, Icon = LoadIcon(0, 32512), Tip = "Minutes", Info = "", InfoTitle = "" }; Shell_NotifyIcon(0, ref icon);
    }
    private nint OnMessage(nint window, uint message, nint w, nint l, nuint id, nuint data)
    {
        if (message == 0x0312 && w == 1) { record(); return 0; }
        if (message == 0x0010 && !exiting) { ShowWindow(hwnd, 0); return 0; }
        if (message == 0x8001)
        {
            var mouse = (uint)l & 0xffff;
            if (mouse == 0x0203) show();
            if (mouse == 0x0205)
            {
                var menu = CreatePopupMenu();
                try
                {
                    AppendMenu(menu, 0, 1, "Open Minutes"); AppendMenu(menu, 0, 7, "Record Screen"); AppendMenu(menu, 0, 2, "Record Voice"); AppendMenu(menu, 0, 3, "Stop Recording"); AppendMenu(menu, 0, 4, "New Note"); AppendMenu(menu, 0, 5, "Settings…"); AppendMenu(menu, 0x800, 0, ""); AppendMenu(menu, 0, 6, "Quit Minutes");
                    GetCursorPos(out var point); SetForegroundWindow(hwnd); var command = TrackPopupMenu(menu, 0x100 | 0x2, point.X, point.Y, 0, hwnd, 0);
                    switch (command) { case 1: show(); break; case 2: chooseMode("voice"); break; case 7: chooseMode("screen"); break; case 3: stop(); break; case 4: note(); break; case 5: settings(); break; case 6: if (canQuit()) { exiting = true; PostMessage(hwnd, 0x0010, 0, 0); } else show(); break; }
                }
                finally { DestroyMenu(menu); }
            }
            return 0;
        }
        return DefSubclassProc(window, message, w, l);
    }
    public void SetRecording(bool recording)
    {
        SetWindowDisplayAffinity(hwnd, recording ? 0x11u : 0u); icon.Tip = recording ? "Minutes · Recording" : "Minutes"; Shell_NotifyIcon(1, ref icon);
    }
    [DllImport("user32.dll")] private static extern bool SetWindowDisplayAffinity(nint hwnd, uint affinity);
    public static bool IsStartupEnabled => Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")?.GetValue("Minutes") != null;
    public static void SetStartup(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("Minutes", "\"" + Environment.ProcessPath + "\""); else key.DeleteValue("Minutes", false);
    }
    public static void SignIn(string provider, AppSettings settings)
    {
        if (provider is "off" or "ollama") throw new InvalidOperationException("This provider has no sign-in");
        var tool = settings.FindTool(provider) ?? throw new IOException(provider + " CLI not found");
        var args = provider switch { "claude" => new[] { "auth", "login" }, "codex" => new[] { "login" }, _ => Array.Empty<string>() };
        var command = string.Join(" ", new[] { tool }.Concat(args).Select(ToolProcess.CmdQuote));
        var terminal = ToolProcess.Find("wt");
        var start = new ProcessStartInfo(terminal ?? Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe") { UseShellExecute = true };
        if (terminal != null) { start.ArgumentList.Add("new-tab"); start.ArgumentList.Add("cmd.exe"); }
        start.ArgumentList.Add("/d"); start.ArgumentList.Add("/k"); start.ArgumentList.Add(command); Process.Start(start);
    }
    public void Dispose() { UnregisterHotKey(hwnd, 1); Shell_NotifyIcon(2, ref icon); RemoveWindowSubclass(hwnd, callback, 1); }
    private delegate nint SubclassProc(nint hwnd, uint message, nint w, nint l, nuint id, nuint data);
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint Size; public nint Window; public uint Id, Flags, CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nint w, nint l);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [DllImport("user32.dll")] private static extern bool RegisterHotKey(nint hwnd, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(nint hwnd, int id);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint LoadIcon(nint instance, nint name);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern int TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(nint hwnd, int command);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint hwnd, uint message, nint w, nint l);
}
