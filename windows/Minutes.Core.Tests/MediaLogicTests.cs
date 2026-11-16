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

public sealed class SwiftDateTests
{
    [Fact] public void DatesWriteWholeSecondsInUtcForSwiftDecoder()
    {
        var text=System.Text.Json.JsonSerializer.Serialize(new MeetingMeta{StartedAt=DateTimeOffset.Parse("2026-10-30T14:00:00.1234567+07:00")},JsonFiles.Options);Assert.Contains("\"startedAt\": \"2026-10-30T07:00:00Z\"",text);Assert.DoesNotContain("1234567",text);File.WriteAllText(Path.Combine(AppContext.BaseDirectory,"interop-meta.json"),text);
    }
    [Fact] public void IncompleteMetaIsNotInventedAsNewMeeting()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-invalid-"+Guid.NewGuid());Directory.CreateDirectory(root);try{File.WriteAllText(Path.Combine(root,"meta.json"),"{}");Assert.Null(Workspace.ReadMeta(root));}finally{Directory.Delete(root,true);}
    }
}

public sealed class DirectoryTransferTests
{
    [Fact] public void CrossVolumeFallbackPublishesWholeTreeBeforeRemovingStaging()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-transfer-"+Guid.NewGuid());var source=Path.Combine(root,"staging");var target=Path.Combine(root,"workspace","meeting");Directory.CreateDirectory(Path.Combine(source,"frames"));File.WriteAllText(Path.Combine(source,"meta.json"),"synthetic");File.WriteAllText(Path.Combine(source,"frames","00-00-01.jpg"),"synthetic");
        try{DirectoryTransfer.CopyThenMove(source,target);Assert.False(Directory.Exists(source));Assert.Equal("synthetic",File.ReadAllText(Path.Combine(target,"frames","00-00-01.jpg")));Assert.DoesNotContain(Directory.GetDirectories(Path.GetDirectoryName(target)!),p=>Path.GetFileName(p).StartsWith('.'));}
        finally{Directory.Delete(root,true);}
    }
    [Fact] public void ExistingDestinationIsNeverOverwritten()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-transfer-"+Guid.NewGuid());var source=Path.Combine(root,"source");var target=Path.Combine(root,"target");Directory.CreateDirectory(source);Directory.CreateDirectory(target);
        try{Assert.Throws<IOException>(()=>DirectoryTransfer.CopyThenMove(source,target));Assert.True(Directory.Exists(source));}
        finally{Directory.Delete(root,true);}
    }
}

public sealed class RepairFailureTests
{
    [Fact] public void FailedSecondPassKeepsCleanedFirstPass()
    {
        var result=TranscriptCleaner.Clean([new(1,2,"a long sentence"),new(3,4,"a long sentence"),new(5,6,"a long sentence")],(_,_)=>throw new TimeoutException("synthetic timeout"));Assert.Single(result.Lines);Assert.Empty(result.Retried);
    }
}

public sealed class OptionalFileTests
{
    [Theory][InlineData("groups.json")][InlineData("comments.json")]
    public void InvalidOptionalJsonDoesNotCrashWorkspace(string name)
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-optional-"+Guid.NewGuid());Directory.CreateDirectory(root);File.WriteAllText(Path.Combine(root,name),"{interrupted");
        try{if(name=="groups.json")Assert.Empty(new Workspace(root).Groups());else Assert.Empty(CommentFiles.Read(root));}finally{Directory.Delete(root,true);}
    }
}

public sealed class CommentMigrationTests
{
    [Fact] public void LegacyReplyBecomesThreadMessageWithOriginalRevisionIdentity()
    {
        var folder=Path.Combine(Path.GetTempPath(),"minutes-comment-"+Guid.NewGuid());Directory.CreateDirectory(folder);
        var id=Guid.NewGuid().ToString();
        JsonFiles.Write(Path.Combine(folder,"comments.json"),new[]{new{id,target="summary",quote="Synthetic",prefix="before",suffix="after",text="Fix this",author="Reader",createdAt=DateTimeOffset.Parse("2026-10-30T10:00:00Z"),reply=new{text="Fixed",at=DateTimeOffset.Parse("2026-10-30T10:01:00Z"),model="sonnet",changed=true,revisedHash="synthetic-hash"}}});
        try{var c=Assert.Single(CommentFiles.Read(folder));var message=Assert.Single(c.Replies!);Assert.Equal(id,message.Id);Assert.Equal("synthetic-hash",message.Revised!["summary.md"]);Assert.Equal("Claude",message.Author);CommentFiles.Save(folder,[c],"Synthetic");Assert.DoesNotContain("\"reply\":",File.ReadAllText(Path.Combine(folder,"comments.json")));}
        finally{Directory.Delete(folder,true);}
    }
    [Fact] public void MissingRequiredCommentFieldsAreNotInvented()
    {
        var folder=Path.Combine(Path.GetTempPath(),"minutes-comment-"+Guid.NewGuid());Directory.CreateDirectory(folder);File.WriteAllText(Path.Combine(folder,"comments.json"),"[{}]");try{Assert.Empty(CommentFiles.Read(folder));}finally{Directory.Delete(folder,true);}
    }
}

public sealed class NoteClassificationTests
{
    [Theory][InlineData("me.wav")][InlineData("others.flac")][InlineData("meeting.mp4")][InlineData("transcript.md")]
    public void ExistingRecordingWinsOverLegacyNoteFlag(string file)
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-note-"+Guid.NewGuid());Directory.CreateDirectory(root);var meta=new MeetingMeta{Note=true};
        try{Assert.True(Workspace.IsNote(root,meta));File.WriteAllText(Path.Combine(root,file),"synthetic");Assert.False(Workspace.IsNote(root,meta));Assert.Equal("screen",meta.RecordMode);}
        finally{Directory.Delete(root,true);}
    }
}

public sealed class RetentionFailureTests
{
    [Fact] public void LockedTrackDoesNotLoseSuccessfulDeletionMarkers()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-retention-"+Guid.NewGuid());var workspace=new Workspace(root);var meeting=workspace.MakeNote();var now=DateTimeOffset.Parse("2026-10-30T10:00:00Z");workspace.Update(meeting.Folder,m=>{m.Mode="screen";m.Note=false;m.StartedAt=now.AddDays(-91);m.EndedAt=now.AddDays(-91);});foreach(var n in new[]{"meeting.mp4","me.wav","others.wav","transcript.md"})File.WriteAllText(Path.Combine(meeting.Folder,n),"synthetic");
        try{Housekeeping.Run(workspace,now,new(90,90),delete:path=>{if(Path.GetFileName(path)=="others.wav")throw new IOException("synthetic lock");File.Delete(path);});var meta=Workspace.ReadMeta(meeting.Folder)!;Assert.Equal(now,meta.VideoDeletedAt);Assert.Equal(now,meta.AudioDeletedAt);Assert.True(File.Exists(Path.Combine(meeting.Folder,"others.wav")));Assert.True(File.Exists(Path.Combine(meeting.Folder,"transcript.md")));}
        finally{Directory.Delete(root,true);}
    }
}
