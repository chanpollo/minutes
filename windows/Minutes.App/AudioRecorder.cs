using System.Diagnostics;
using NAudio.Wave;
using NAudio.CoreAudioApi;
using NAudio.Wave.SampleProviders;
using Minutes.Core;

namespace Minutes.App;

public sealed class AudioRecorder : IDisposable
{
    private sealed class Track : IDisposable
    {
        private readonly IWaveIn capture;
        private readonly WaveFileWriter writer;
        private readonly Stopwatch clock;
        private readonly object gate = new();
        private readonly TaskCompletionSource stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
        private bool muted;
        private bool disposed;
        public string RawFile { get; }
        public Track(IWaveIn capture,string rawFile,Stopwatch clock)
        {
            this.capture=capture;this.clock=clock;RawFile=rawFile;writer=new(rawFile,capture.WaveFormat);
            capture.DataAvailable+=OnData;capture.RecordingStopped+=(_,e)=>{if(e.Exception!=null)stopped.TrySetException(e.Exception);else stopped.TrySetResult();};
        }
        public void Start()=>capture.StartRecording();
        public void SetMuted(bool value){lock(gate)muted=value;}
        private void Pad(long wanted)
        {
            var gap=wanted-writer.Length;var zeros=new byte[16384];while(gap>0){var count=(int)Math.Min(gap,zeros.Length);writer.Write(zeros,0,count);gap-=count;}
        }
        private void OnData(object? sender,WaveInEventArgs e)
        {
            lock(gate)
            {
                if(disposed)return;
                var format=capture.WaveFormat;var end=(long)(clock.Elapsed.TotalSeconds*format.SampleRate)*format.BlockAlign;
                Pad(Math.Max(0,end-e.BytesRecorded));
                if(muted)writer.Write(new byte[e.BytesRecorded],0,e.BytesRecorded);else writer.Write(e.Buffer,0,e.BytesRecorded);
            }
        }
        public async Task StopAsync()
        {
            capture.StopRecording();await stopped.Task.WaitAsync(TimeSpan.FromSeconds(10));
            lock(gate){Pad((long)(clock.Elapsed.TotalSeconds*capture.WaveFormat.SampleRate)*capture.WaveFormat.BlockAlign);writer.Flush();}
        }
        public void Dispose(){lock(gate){if(disposed)return;disposed=true;capture.Dispose();writer.Dispose();}}
    }
    private readonly Stopwatch clock=new();
    private Track? mic,others;
    private string? folder;
    public Stopwatch RecordingClock=>clock;
    public bool IsRecording=>folder!=null;
    public bool Muted { get; private set; }
    public async Task<string> StartAsync(string directory, uint? processId = null)
    {
        if(IsRecording)throw new InvalidOperationException("Already recording");Directory.CreateDirectory(directory);
        try
        {
            clock.Restart();mic=new(new WasapiCapture(),Path.Combine(directory,"me.capture.wav"),clock);
            IWaveIn call;
            var scope="Whole-system audio";
            try{call=processId is {} pid?await ProcessLoopbackCapture.CreateAsync(pid):new WasapiLoopbackCapture();if(processId!=null)scope="Meeting app audio";}
            catch(Exception e)when(e is System.Runtime.InteropServices.COMException or PlatformNotSupportedException or TimeoutException){call=new WasapiLoopbackCapture();}
            others=new(call,Path.Combine(directory,"others.capture.wav"),clock);
            mic.Start();others.Start();folder=directory;return scope;
        }
        catch{DisposeTracks();clock.Stop();throw;}
    }
    public void Mute(bool value){Muted=value;mic?.SetMuted(value);}
    public async Task StopAsync()
    {
        if(folder==null)return;var target=folder;
        try{if(mic!=null)await mic.StopAsync();if(others!=null)await others.StopAsync();}
        finally{clock.Stop();DisposeTracks();folder=null;}
        await Task.Run(()=>{ConvertTrack(Path.Combine(target,"me.capture.wav"),Path.Combine(target,"me.wav"));ConvertTrack(Path.Combine(target,"others.capture.wav"),Path.Combine(target,"others.wav"));});
    }
    public static void Recover(string folder)
    {
        foreach(var name in new[]{"me","others"})
        {
            var raw=Path.Combine(folder,name+".capture.wav");if(!File.Exists(raw))continue;
            using(var file=new FileStream(raw,FileMode.Open,FileAccess.ReadWrite,FileShare.None))
            using(var read=new BinaryReader(file,System.Text.Encoding.ASCII,true))
            using(var write=new BinaryWriter(file,System.Text.Encoding.ASCII,true))
            {
                if(file.Length<44||new string(read.ReadChars(4))!="RIFF")throw new IOException("The interrupted audio has no WAV header");
                file.Position=4;write.Write(checked((uint)(file.Length-8)));file.Position=12;
                while(file.Position+8<=file.Length)
                {
                    var tag=new string(read.ReadChars(4));var size=read.ReadUInt32();
                    if(tag=="data"){file.Position-=4;write.Write(checked((uint)(file.Length-file.Position-4)));break;}
                    file.Position+=size+(size%2);
                }
            }
            ConvertTrack(raw,Path.Combine(folder,name+".wav"));
        }
    }
    private static void ConvertTrack(string raw,string target)
    {
        using(var reader=new AudioFileReader(raw))
        {
            ISampleProvider source=reader;
            if(source.WaveFormat.Channels==2)source=new StereoToMonoSampleProvider(source){LeftVolume=.5f,RightVolume=.5f};
            else if(source.WaveFormat.Channels!=1)throw new IOException("Unsupported audio channel layout");
            var resampled=new WdlResamplingSampleProvider(source,16000);WaveFileWriter.CreateWaveFile16(target,resampled);
        }
        File.Delete(raw);
    }
    private void DisposeTracks(){mic?.Dispose();others?.Dispose();mic=others=null;Muted=false;}
    public void Dispose(){DisposeTracks();clock.Stop();folder=null;}
}
