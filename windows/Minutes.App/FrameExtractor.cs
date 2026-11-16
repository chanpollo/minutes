using Minutes.Core;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Globalization;
using Windows.Graphics.Imaging;
using Windows.Media.Editing;
using Windows.Media.Ocr;
using Windows.Storage;

namespace Minutes.App;

internal static class FrameExtractor
{
    public static async Task<IReadOnlyList<VideoFrame>> ExtractAsync(string folder,IProgress<string>? progress=null,CancellationToken cancel=default)
    {
        var video=Path.Combine(folder,"meeting.mp4");if(!File.Exists(video))return [];
        var clip=await MediaClip.CreateFromFileAsync(await StorageFile.GetFileFromPathAsync(video));var composition=new MediaComposition();composition.Clips.Add(clip);var samples=new List<FrameSample>();
        for(var t=0d;t<clip.OriginalDuration.TotalSeconds;t++)
        {
            cancel.ThrowIfCancellationRequested();progress?.Report($"Reading video · {Transcripts.Clock(t)}");
            using var image=await composition.GetThumbnailAsync(TimeSpan.FromSeconds(t),64,36,VideoFramePrecision.NearestFrame);
            var decoder=await BitmapDecoder.CreateAsync(image);
            using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Ignore);
            var pixels=new byte[64*36*4];bitmap.CopyToBuffer(pixels.AsBuffer());var cells=new byte[64*36];
            for(var i=0;i<cells.Length;i++)cells[i]=(byte)((pixels[i*4]*29+pixels[i*4+1]*150+pixels[i*4+2]*77)/256);
            samples.Add(new(t,cells));
        }
        var frames=new List<VideoFrame>();
        foreach(var moment in FrameSelection.Moments(samples))
        {
            cancel.ThrowIfCancellationRequested();var path=await CaptureAsync(folder,moment.Shot,moment.Time);var text=await RecognizeAsync(Path.Combine(folder,path));frames.Add(new(Math.Floor(moment.Time),path,text));
        }
        JsonFiles.Write(Path.Combine(folder,"frames","frames.json"),frames);return frames;
    }
    public static async Task<string> CaptureAsync(string folder,double seconds,double? nameTime=null)
    {
        var path="frames/"+Transcripts.Clock(nameTime??seconds).Replace(':','-')+".jpg";var target=Path.Combine(folder,path);if(File.Exists(target))return path;
        var video=await StorageFile.GetFileFromPathAsync(Path.Combine(folder,"meeting.mp4"));var clip=await MediaClip.CreateFromFileAsync(video);var props=clip.GetVideoEncodingProperties();var composition=new MediaComposition();composition.Clips.Add(clip);
        using var image=await composition.GetThumbnailAsync(TimeSpan.FromSeconds(Math.Clamp(seconds,0,Math.Max(0,clip.OriginalDuration.TotalSeconds-.1))),(int)props.Width,(int)props.Height,VideoFramePrecision.NearestFrame);
        var decoder=await BitmapDecoder.CreateAsync(image);using var bitmap=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Ignore);
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);var part=target+".partial";File.WriteAllBytes(part,[]);
        try
        {
            var file=await StorageFile.GetFileFromPathAsync(part);using(var stream=await file.OpenAsync(FileAccessMode.ReadWrite)){var encoder=await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId,stream);encoder.SetSoftwareBitmap(bitmap);await encoder.FlushAsync();}
            File.Move(part,target,true);return path;
        }
        finally{if(File.Exists(part))File.Delete(part);}
    }
    private static async Task<string> RecognizeAsync(string path)
    {
        var file=await StorageFile.GetFileFromPathAsync(path);using var stream=await file.OpenReadAsync();var decoder=await BitmapDecoder.CreateAsync(stream);using var original=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied);
        SoftwareBitmap? scaled=null;
        try
        {
            var bitmap=original;
            if(original.PixelWidth>OcrEngine.MaxImageDimension||original.PixelHeight>OcrEngine.MaxImageDimension)
            {
                var factor=Math.Min((double)OcrEngine.MaxImageDimension/original.PixelWidth,(double)OcrEngine.MaxImageDimension/original.PixelHeight);
                scaled=await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8,BitmapAlphaMode.Premultiplied,new BitmapTransform{ScaledWidth=(uint)(original.PixelWidth*factor),ScaledHeight=(uint)(original.PixelHeight*factor)},ExifOrientationMode.RespectExifOrientation,ColorManagementMode.DoNotColorManage);bitmap=scaled;
            }
            var texts=new List<string>();foreach(var language in new[]{"th-TH","en-US"})
            {if(!OcrEngine.IsLanguageSupported(new Language(language)))continue;var engine=OcrEngine.TryCreateFromLanguage(new Language(language));if(engine!=null){var result=await engine.RecognizeAsync(bitmap);texts.AddRange(result.Lines.Select(l=>l.Text));}}
            return string.Join("\n",texts.Distinct(StringComparer.Ordinal));
        }
        finally{scaled?.Dispose();}
    }
}
