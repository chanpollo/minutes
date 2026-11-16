using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;
using NAudio.Wave;

namespace Minutes.App;

internal sealed class ProcessLoopbackCapture : IWaveIn
{
    private readonly AudioClient client;
    private readonly EventWaitHandle ready=new(false,EventResetMode.AutoReset);
    private Thread? thread;
    private volatile bool stopping;
    public WaveFormat WaveFormat { get; set; } = new(16000,16,1);
    public event EventHandler<WaveInEventArgs>? DataAvailable;
    public event EventHandler<StoppedEventArgs>? RecordingStopped;
    private ProcessLoopbackCapture(AudioClient client){this.client=client;}
    public static async Task<ProcessLoopbackCapture> CreateAsync(uint processId)
    {
        if(!OperatingSystem.IsWindowsVersionAtLeast(10,0,20348))throw new PlatformNotSupportedException("Process loopback needs Windows build 20348 or later");
        var parameters=new ActivationParameters{Type=1,ProcessId=processId,Mode=0};
        var blob=Marshal.AllocCoTaskMem(Marshal.SizeOf<ActivationParameters>());
        var variant=Marshal.AllocCoTaskMem(Marshal.SizeOf<BlobVariant>());
        var completion=new Completion();
        try
        {
            Marshal.StructureToPtr(parameters,blob,false);Marshal.StructureToPtr(new BlobVariant{Type=65,Size=Marshal.SizeOf<ActivationParameters>(),Data=blob},variant,false);
            var iid=typeof(IAudioClient).GUID;
            Marshal.ThrowExceptionForHR(ActivateAudioInterfaceAsync("VAD\\Process_Loopback",ref iid,variant,completion,out var operation));
            // Activation storage and handler must live until the callback completes.
            var activated=await completion.Result.Task.WaitAsync(TimeSpan.FromSeconds(15));GC.KeepAlive(operation);
            return new(new AudioClient((IAudioClient)activated));
        }
        finally{GC.KeepAlive(completion);Marshal.FreeCoTaskMem(variant);Marshal.FreeCoTaskMem(blob);}
    }
    public void StartRecording()
    {
        if(thread!=null)throw new InvalidOperationException("Already started");
        client.Initialize(AudioClientShareMode.Shared,AudioClientStreamFlags.Loopback|AudioClientStreamFlags.EventCallback,0,0,WaveFormat,Guid.Empty);
        client.SetEventHandle(ready.SafeWaitHandle.DangerousGetHandle());var capture=client.AudioCaptureClient;client.Start();
        thread=new Thread(()=>
        {
            Exception? error=null;
            try
            {
                while(!stopping)
                {
                    ready.WaitOne(100);
                    while(capture.GetNextPacketSize()>0)
                    {
                        var buffer=capture.GetBuffer(out var frames,out var flags);var bytes=new byte[frames*WaveFormat.BlockAlign];
                        try{if((flags&AudioClientBufferFlags.Silent)==0)Marshal.Copy(buffer,bytes,0,bytes.Length);}finally{capture.ReleaseBuffer(frames);}
                        DataAvailable?.Invoke(this,new(bytes,bytes.Length));
                    }
                }
            }
            catch(Exception e){error=e;}
            finally{try{client.Stop();}catch(Exception e){error??=e;}RecordingStopped?.Invoke(this,new(error));}
        }){IsBackground=true,Name="Minutes process audio"};thread.Start();
    }
    public void StopRecording(){stopping=true;ready.Set();}
    public void Dispose(){StopRecording();thread?.Join();client.Dispose();ready.Dispose();}
    [StructLayout(LayoutKind.Sequential)]private struct ActivationParameters{public uint Type,ProcessId,Mode;}
    [StructLayout(LayoutKind.Explicit,Size=24)]private struct BlobVariant{[FieldOffset(0)]public ushort Type;[FieldOffset(8)]public int Size;[FieldOffset(16)]public nint Data;}
    [ComVisible(true),Guid("41D949AB-9862-444A-80F6-C261334DA5EB"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ICompletion{void ActivateCompleted(IAsyncOperation operation);}
    [ComImport,Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IAsyncOperation{void GetActivateResult(out int result,[MarshalAs(UnmanagedType.IUnknown)]out object activated);}
    [ComVisible(true),Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]public interface IAgileObject{}
    [ComVisible(true),ClassInterface(ClassInterfaceType.None)]private sealed class Completion:ICompletion,IAgileObject
    {
        public TaskCompletionSource<object> Result { get; }=new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void ActivateCompleted(IAsyncOperation operation){try{operation.GetActivateResult(out var hr,out var activated);Marshal.ThrowExceptionForHR(hr);Result.TrySetResult(activated);}catch(Exception e){Result.TrySetException(e);}}
    }
    [DllImport("Mmdevapi.dll",ExactSpelling=true,CharSet=CharSet.Unicode)]private static extern int ActivateAudioInterfaceAsync([MarshalAs(UnmanagedType.LPWStr)]string device,ref Guid iid,nint parameters,ICompletion completion,out IAsyncOperation operation);
}
