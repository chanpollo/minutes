using Minutes.Core;
using Xunit;

namespace Minutes.Core.Tests;
public sealed class DetectorTests
{
    private static readonly DateTimeOffset Now=DateTimeOffset.Parse("2026-10-30T10:00:00Z");
    private static readonly MicUser Call=new("Microsoft Teams","ms-teams",123);
    private static IReadOnlyList<DetectorAction> Poll(MeetingDetector d,int second,IReadOnlyList<MicUser>? users=null,RecordedCall? recording=null,bool stop=false,ISet<string>? output=null,bool always=false)=>d.Poll(users??[Call],Now.AddSeconds(second),recording,null,stop,_=>true,_=>always,outputApps:output);
    [Fact] public void TwoPollsBeforePrompt(){var d=new MeetingDetector();Assert.Empty(Poll(d,0));Assert.Equal("ask",Assert.Single(Poll(d,2)).Kind);}
    [Fact] public void NotNowRequiresReleaseOrFifteenMinutes(){var d=new MeetingDetector();Poll(d,0);d.Decline(Call.AppName,Now);Assert.Empty(Poll(d,2));Assert.Empty(Poll(d,899));Assert.Equal("ask",Assert.Single(Poll(d,900)).Kind);}
    [Fact] public void AlwaysRecordBecomesAskOnlyAfterManualStop(){var d=new MeetingDetector();Poll(d,0);Assert.Equal("recordWithoutAsking",Assert.Single(Poll(d,2,always:true)).Kind);d.StoppedByHand(Call.AppName,Now.AddSeconds(3));Assert.Equal("ask",Assert.Single(Poll(d,4,always:true)).Kind);}
    [Fact] public void StopCardAtThreeSecondsAndStopAtThirty()
    {
        var d=new MeetingDetector();var r=new RecordedCall(Call.AppName,true);Assert.Empty(Poll(d,0,[],r));Assert.Empty(Poll(d,2,[],r));Assert.Equal("askToStop",Assert.Single(Poll(d,3,[],r)).Kind);Assert.Equal("stop",Assert.Single(Poll(d,30,[],r,true)).Kind);
    }
    [Fact] public void AnotherAppDoesNotKeepRecordedCallAlive()
    {
        var d=new MeetingDetector();var r=new RecordedCall(Call.AppName,true);Poll(d,0,[],r);Assert.Equal("stop",Assert.Single(Poll(d,30,[new("Other","other",999)],r)).Kind);
    }
    [Fact] public void MicReturnsWhileStopCardShownAsksSameCall()
    {var actions=Poll(new(),4,[Call],new(Call.AppName,true),true);Assert.Equal(new[]{"closeStopPrompt","askSameCall"},actions.Select(a=>a.Kind));}
    [Fact] public void KeepRecordingWaitsForPreviouslySeenOutputToEnd()
    {
        var d=new MeetingDetector{KeepRecording=true};var r=new RecordedCall(Call.AppName,true);Poll(d,0,[],r,output:new HashSet<string>{Call.AppName});Assert.Empty(Poll(d,3,[],r));Assert.Empty(Poll(d,32,[],r));Assert.Equal("stop",Assert.Single(Poll(d,33,[],r)).Kind);
    }
    [Fact] public void KeepRecordingWithUnknownOutputNeverAutoStops()
    {var d=new MeetingDetector{KeepRecording=true};Assert.Empty(Poll(d,0,[],new(Call.AppName,true)));Assert.Empty(Poll(d,9999,[],new(Call.AppName,true)));}
    [Fact] public void ManualRecordingHasNoAutoStop()=>Assert.Empty(Poll(new(),9999,[],new(null,false)));
    [Fact] public void CalendarNewMeetingClearsDecline()
    {
        var d=new MeetingDetector();Poll(d,0);d.Decline(Call.AppName,Now);var actions=d.Poll([Call],Now.AddSeconds(2),null,null,false,_=>true,_=>false,(_,_)=>true);Assert.Equal("ask",Assert.Single(actions).Kind);
    }
    [Fact] public void NpmShimEntryIsResolvedWithoutCmd()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-shim-"+Guid.NewGuid());Directory.CreateDirectory(Path.Combine(root,"node_modules","synthetic"));
        try{var entry=Path.Combine(root,"node_modules","synthetic","cli.js");File.WriteAllText(entry,"");var shim=Path.Combine(root,"synthetic.cmd");File.WriteAllText(shim,"@echo off\n\"%dp0%\\node.exe\" \"%dp0%\\node_modules\\synthetic\\cli.js\" %*\n");Assert.Equal(entry,ToolProcess.NpmEntry(shim));}finally{Directory.Delete(root,true);}
    }
    [Fact] public void RetentionProtectsTranscriptAndUntranscribedAudio()
    {
        var root=Path.Combine(Path.GetTempPath(),"minutes-retain-"+Guid.NewGuid());Directory.CreateDirectory(root);
        try
        {
            foreach(var name in new[]{"meeting.mp4","me.wav","notes.md"})File.WriteAllText(Path.Combine(root,name),"synthetic");
            var meta=new MeetingMeta{StartedAt=Now.AddDays(-91),Mode="screen"};var policy=new RetentionPolicy(90,90);
            var plan=Housekeeping.Plan(root,meta,Now,policy);Assert.Single(plan.Videos);Assert.Empty(plan.Tracks);File.WriteAllText(Path.Combine(root,"transcript.md"),"synthetic");Assert.Single(Housekeeping.Plan(root,meta,Now,policy).Tracks);Assert.Empty(Housekeeping.Plan(root,meta,Now,policy,true).Videos);
            meta.StartedAt=Now.AddDays(-90);Assert.Empty(Housekeeping.Plan(root,meta,Now,policy).Videos);
        }
        finally{Directory.Delete(root,true);}
    }
}
