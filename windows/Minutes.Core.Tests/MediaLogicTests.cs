using Minutes.Core;
using Xunit;

namespace Minutes.Core.Tests;
public sealed class MediaLogicTests
{
    private static byte[] Slide(int offset=0)=>Enumerable.Range(0,64*36).Select(i=>(byte)((i%64<32?40:180)+offset)).ToArray();
    [Fact] public void StillSlidesLongerThanThreeSecondsAreKeptOnce()
    {
        var samples=Enumerable.Range(0,12).Select(i=>new FrameSample(i,Slide(i<6?0:20))).ToArray();var moments=FrameSelection.Moments(samples);Assert.Equal(2,moments.Count);Assert.Equal(0,moments[0].Time);Assert.Equal(6,moments[1].Time);
    }
    [Fact] public void BlankAndTooShortSlidesAreRejected()
    {Assert.Empty(FrameSelection.Moments(Enumerable.Range(0,10).Select(i=>new FrameSample(i,new byte[64*36])).ToArray()));Assert.Empty(FrameSelection.Moments([new(0,Slide()),new(1,Slide())]));}
    [Fact] public void RecurringSlideDoesNotCreateDuplicate()
    {
        var moments=FrameSelection.Moments(Enumerable.Range(0,18).Select(i=>new FrameSample(i,Slide(i>=6&&i<12?20:0))).ToArray());Assert.Equal(2,moments.Count);
    }
    [Theory][InlineData(0,"ศูนย์")][InlineData(11,"สิบเอ็ด")][InlineData(21,"ยี่สิบเอ็ด")][InlineData(101,"หนึ่งร้อยเอ็ด")][InlineData(1000001,"หนึ่งล้านหนึ่ง")]
    public void ThaiNumbers(int n,string expected)=>Assert.Equal(expected,ThaiSpeech.Number(n));
    [Theory][InlineData(14,52,"บ่ายสองโมงห้าสิบสองนาที")][InlineData(21,30,"สามทุ่มครึ่ง")][InlineData(0,0,"เที่ยงคืน")][InlineData(13,0,"บ่ายโมง")]
    public void ThaiTime(int hour,int minute,string expected)=>Assert.Equal(expected,ThaiSpeech.Time(hour,minute));
    [Fact] public void BriefingStripsHeaderStampAndPictures()
    {Assert.Equal("## Summary\nText",Briefing.SummaryBody("# Test\n\n2026-10-30 · Summarised by Claude Sonnet\n\n## Summary\nText\n![](frames/00-00-01.jpg)"));}
    [Fact] public void BriefingCleansMarkdownAndSplitsEnglish()
    {Assert.Equal("Heading\nFirst.\nSecond!\n\nThai ค่ะ",Briefing.Clean("## Heading\n- **First.** Second!\n| table |\n---\n\nThai ค่ะ"));}
    [Theory][InlineData("สวัสดีครับ this is jargon","thai")][InlineData("An English meeting summary.","english")]
    public void BriefingLanguageByLetterShare(string text,string expected)=>Assert.Equal(expected,Briefing.Language(text));
    [Fact] public async Task ModelsRejectCorruption()
    {
        var file=Path.Combine(Path.GetTempPath(),"minutes-model-"+Guid.NewGuid());
        try{await File.WriteAllTextAsync(file,"synthetic");await Assert.ThrowsAsync<InvalidDataException>(()=>ModelStore.VerifyAsync(file,new string('0',64)));}
        finally{File.Delete(file);}
    }
}

public sealed class CompatibilityTests
{
    [Fact] public void AttachmentLinksDecodeSpacesAndRejectTraversal()
    {
        Assert.Equal("![](attachments/Slide%20%281%29.png)",Attachments.Line("Slide (1).png"));
        Assert.Equal(new[]{"attachments/Slide (1).png"},Attachments.Referenced("![](attachments/Slide%20%281%29.png) ![](attachments/%2e%2e/secret.png) ![](attachments/.hidden)"));
    }
    [Fact] public void LeakCorrelationFindsLagAndRejectsConstantOrShortTracks()
    {
        var random=new Random(42);var a=Enumerable.Range(0,300).Select(_=>random.NextDouble()).ToArray();var b=new double[3].Concat(a).ToArray();Assert.True(AudioAnalysis.Leak(a,b)>.99);Assert.Equal(0,AudioAnalysis.Leak(a.Take(50).ToArray(),b));Assert.Equal(0,AudioAnalysis.Leak(new double[300],new double[300]));
    }
}

public sealed class SpeakerRenameTests
{
    [Fact] public void ChangesOnlyExactTurnLabels()
    {
        const string input="# Meeting\n\n**[00:00:01] Me:** Speaker 1 said this.\n\n**[00:00:02] Speaker 1:** Hello.\n";
        var changed=Transcripts.RenameSpeaker(input,"Speaker 1","Synthetic Voice");Assert.Contains("Me:** Speaker 1 said this",changed);Assert.Contains("00:00:02] Synthetic Voice:** Hello",changed);
    }
    [Theory][InlineData("bad\nname")][InlineData("bad:name")][InlineData(" ")]
    public void RefusesNamesThatBreakTranscriptMarkers(string name)=>Assert.Throws<ArgumentException>(()=>Transcripts.RenameSpeaker("","Me",name));
}
