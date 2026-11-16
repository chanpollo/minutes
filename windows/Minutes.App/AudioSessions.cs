using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using Minutes.Core;
using System.Diagnostics;

namespace Minutes.App;

internal static class AudioSessions
{
    public static IReadOnlyList<MicUser> Capture() => Enumerate(DataFlow.Capture, false);
    public static ISet<string> Playing() => Enumerate(DataFlow.Render, true).Select(u => u.AppName).ToHashSet(StringComparer.Ordinal);
    private static IReadOnlyList<MicUser> Enumerate(DataFlow flow, bool audible)
    {
        var result = new List<MicUser>(); using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(flow, DeviceState.Active))
        {
            using (device)
            {
                var manager = device.AudioSessionManager; manager.RefreshSessions();
                for (var i = 0; i < manager.Sessions.Count; i++)
                {
                    using var session = manager.Sessions[i];
                    if (session.State != AudioSessionState.AudioSessionStateActive || session.IsSystemSoundsSession) continue;
                    if (audible && (session.AudioMeterInformation?.MasterPeakValue ?? 0) <= .001) continue;
                    var pid = session.GetProcessID; if (pid == 0 || pid == Environment.ProcessId) continue;
                    try
                    {
                        using var process = Process.GetProcessById((int)pid); var name = process.ProcessName;
                        result.Add(new(MeetingApps.Known.GetValueOrDefault(name) ?? name, name, pid));
                    }
                    catch (ArgumentException) { }
                    catch (System.ComponentModel.Win32Exception) { }
                }
            }
        }
        return result.DistinctBy(u => u.ProcessId).ToArray();
    }
}
