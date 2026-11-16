using System.Runtime.InteropServices;
using System.Threading.Channels;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;
using Windows.Media.Core;
using Windows.Media.MediaProperties;
using Windows.Media.Transcoding;
using Windows.Media.Editing;
using Windows.Storage;
using Microsoft.UI.Xaml;

namespace Minutes.App;

internal sealed class VideoRecorder : IAsyncDisposable
{
    private readonly IDirect3DDevice device;
    private readonly GraphicsCaptureItem item;
    private Direct3D11CaptureFramePool? pool;
    private GraphicsCaptureSession? session;
    private readonly Channel<Direct3D11CaptureFrame> frames = Channel.CreateBounded<Direct3D11CaptureFrame>(new BoundedChannelOptions(2) { SingleReader = true, SingleWriter = true });
    private readonly TaskCompletionSource first = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly int fps;
    private readonly string quality;
    private TimeSpan? origin, last;
    private Task? encoding;
    private bool stopped;
    private Exception? captureError;
    private string? screenFile;
    public double Offset { get; private set; }
    private VideoRecorder(GraphicsCaptureItem item, int fps, string quality = "balanced") { this.item = item; this.fps = fps; this.quality = quality; device = CreateDevice(); }
    public static VideoRecorder ForMeeting(Window owner, uint? processId, string quality = "balanced")
    {
        if (!GraphicsCaptureSession.IsSupported()) throw new PlatformNotSupportedException("Screen capture is not supported on this PC");
        return new(WindowCapture.Create(WinRT.Interop.WindowNative.GetWindowHandle(owner), processId), quality == "smaller" ? 10 : 15, quality);
    }
    public static async Task<VideoRecorder?> PickAsync(Window owner, int fps = 15)
    {
        if (!GraphicsCaptureSession.IsSupported()) throw new PlatformNotSupportedException("Screen capture is not supported on this PC");
        var picker = new GraphicsCapturePicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(owner));
        var item = await picker.PickSingleItemAsync(); return item == null ? null : new(item, fps);
    }
    public async Task StartAsync(string folder, System.Diagnostics.Stopwatch clock)
    {
        screenFile = Path.Combine(folder, "screen.mov");
        pool = Direct3D11CaptureFramePool.CreateFreeThreaded(device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 3, item.Size);
        pool.FrameArrived += (sender, _) =>
        {
            Direct3D11CaptureFrame? frame;
            try { frame = sender.TryGetNextFrame(); } catch (Exception ex) { if (!stopped) captureError = ex; return; }
            if (frame == null) return;
            if (stopped || last is { } previous && (frame.SystemRelativeTime - previous).TotalSeconds < 1d / fps) { frame.Dispose(); return; }
            if (origin == null) { origin = frame.SystemRelativeTime; Offset = clock.Elapsed.TotalSeconds; first.TrySetResult(); }
            last = frame.SystemRelativeTime; if (!frames.Writer.TryWrite(frame)) frame.Dispose();
        };
        session = pool.CreateCaptureSession(item); session.StartCapture();
        await first.Task.WaitAsync(TimeSpan.FromSeconds(15));
        var video = VideoEncodingProperties.CreateUncompressed(MediaEncodingSubtypes.Bgra8, (uint)item.Size.Width, (uint)item.Size.Height);
        video.FrameRate.Numerator = (uint)fps; video.FrameRate.Denominator = 1;
        var source = new MediaStreamSource(new VideoStreamDescriptor(video)) { BufferTime = TimeSpan.Zero };
        source.Starting += (_, args) => args.Request.SetActualStartPosition(TimeSpan.Zero);
        source.SampleRequested += async (_, args) =>
        {
            var deferral = args.Request.GetDeferral();
            try
            {
                if (await frames.Reader.WaitToReadAsync() && frames.Reader.TryRead(out var frame))
                {
                    var sample = MediaStreamSample.CreateFromDirect3D11Surface(frame.Surface, frame.SystemRelativeTime - origin!.Value);
                    sample.Duration = TimeSpan.FromSeconds(1d / fps); sample.Processed += (_, _) => frame.Dispose(); args.Request.Sample = sample;
                }
                else args.Request.Sample = null;
            }
            catch (Exception ex) { captureError = ex; args.Request.Sample = null; }
            finally { deferral.Complete(); }
        };
        var directory = await StorageFolder.GetFolderFromPathAsync(folder);
        var file = await directory.CreateFileAsync("screen.mov", CreationCollisionOption.ReplaceExisting);
        var stream = await file.OpenAsync(FileAccessMode.ReadWrite);
        var profile = Profile(item.Size.Width, item.Size.Height, fps, quality);
        var transcoder = new MediaTranscoder { HardwareAccelerationEnabled = true };
        var prepared = await transcoder.PrepareMediaStreamSourceTranscodeAsync(source, stream, profile);
        if (!prepared.CanTranscode) { stream.Dispose(); throw new IOException("H.264 encoder: " + prepared.FailureReason); }
        encoding = EncodeAsync();
        async Task EncodeAsync() { try { await prepared.TranscodeAsync(); } finally { stream.Dispose(); } }
    }
    private static MediaEncodingProfile Profile(int width, int height, int fps, string quality)
    {
        var p = MediaEncodingProfile.CreateMp4(VideoEncodingQuality.HD1080p); p.Audio = null;
        p.Video.Width = (uint)((width + 1) / 2 * 2); p.Video.Height = (uint)((height + 1) / 2 * 2); p.Video.FrameRate.Numerator = (uint)fps; p.Video.FrameRate.Denominator = 1; p.Video.Bitrate = (uint)Math.Clamp((long)(width * (double)height * fps / 8 * (quality == "smaller" ? .5 : quality == "best" ? 2 : 1)), 500000, 24000000); return p;
    }
    public async Task StopCaptureAsync()
    {
        stopped = true; session?.Dispose(); session = null; frames.Writer.TryComplete();
        try { if (encoding != null) await encoding; if (captureError != null) throw new IOException("Screen capture stopped unexpectedly", captureError); } finally { pool?.Dispose(); pool = null; }
    }
    public async Task MuxAsync(string folder)
    {
        if (screenFile == null || !File.Exists(screenFile)) return;
        var composition = new MediaComposition();
        if (Offset > .001) composition.Clips.Add(MediaClip.CreateFromColor(Windows.UI.Color.FromArgb(255, 0, 0, 0), TimeSpan.FromSeconds(Offset)));
        composition.Clips.Add(await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(screenFile)));
        foreach (var name in new[] { "me.wav", "others.wav" })
        {
            var file = Path.Combine(folder, name); if (!File.Exists(file)) continue;
            var audio = await BackgroundAudioTrack.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(file)); audio.Volume = .5; composition.BackgroundAudioTracks.Add(audio);
        }
        var directory = await StorageFolder.GetFolderFromPathAsync(folder); var output = await directory.CreateFileAsync("meeting.partial.mp4", CreationCollisionOption.ReplaceExisting);
        var profile = Profile(item.Size.Width, item.Size.Height, fps, quality); profile.Audio = AudioEncodingProperties.CreateAac(48000, 2, 128000);
        var result = await composition.RenderToFileAsync(output, MediaTrimmingPreference.Precise, profile);
        if (result != Windows.Media.Transcoding.TranscodeFailureReason.None) throw new IOException("Meeting mux failed: " + result);
        File.Move(output.Path, Path.Combine(folder, "meeting.mp4"), true); File.Delete(screenFile);
    }
    public async ValueTask DisposeAsync()
    {
        stopped = true; session?.Dispose(); pool?.Dispose(); frames.Writer.TryComplete();
        if (encoding != null) try { await encoding; } catch (Exception) { }
        while (frames.Reader.TryRead(out var frame)) frame.Dispose(); device.Dispose();
    }
    private static IDirect3DDevice CreateDevice()
    {
        nint d3d = 0, context = 0, dxgi = 0, inspectable = 0;
        try
        {
            Marshal.ThrowExceptionForHR(D3D11CreateDevice(0, 1, 0, 0x20, 0, 0, 7, out d3d, out _, out context));
            var iid = new Guid("54EC77FA-1377-44E6-8C32-88FD5F44C84C"); Marshal.ThrowExceptionForHR(Marshal.QueryInterface(d3d, ref iid, out dxgi));
            Marshal.ThrowExceptionForHR(CreateDirect3D11DeviceFromDXGIDevice(dxgi, out inspectable)); return WinRT.MarshalInterface<IDirect3DDevice>.FromAbi(inspectable);
        }
        finally { foreach (var p in new[] { inspectable, dxgi, context, d3d }) if (p != 0) Marshal.Release(p); }
    }
    [DllImport("d3d11.dll")] private static extern int D3D11CreateDevice(nint adapter, uint driver, nint software, uint flags, nint levels, uint count, uint version, out nint device, out uint level, out nint context);
    [DllImport("d3d11.dll")] private static extern int CreateDirect3D11DeviceFromDXGIDevice(nint dxgi, out nint device);
}
