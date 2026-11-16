using System.Text;
using System.Text.Json;
using Minutes.Core;
using Xunit;

namespace Minutes.Core.Tests;

public sealed class ChangelogTests
{
    [Theory]
    [InlineData("0.6.1 (10) — 2026-10-30", 10, "2026-10-30")]
    [InlineData("0.6.1 (build 10) - 2026-10-30", 10, "2026-10-30")]
    [InlineData("0.6.1 (10)", 10, null)]
    [InlineData("0.6.1 – 2026-10-30", null, "2026-10-30")]
    [InlineData("0.6.1", null, null)]
    public void Headings(string text, int? build, string? date)
    { var r = Assert.Single(Changelog.Parse("## " + text)); Assert.Equal("0.6.1", r.Version); Assert.Equal(build, r.Build); Assert.Equal(date, r.Date); }
    [Fact] public void KeepsOrderAndBullets()
    {
        var r = Changelog.Parse("## 0.6.9 (18) — 2026-11-14\n- Ninth.\n## 0.6.8 (17) — 2026-11-13\n- Eighth, one.\n* Eighth, two.\n## 0.6.7 (16) — 2026-11-12\n- Seventh.");
        Assert.Equal(new[] { "0.6.9", "0.6.8", "0.6.7" }, r.Select(x => x.Version)); Assert.Equal(new int?[] { 18, 17, 16 }, r.Select(x => x.Build)); Assert.Equal(new[] { "Eighth, one.", "Eighth, two." }, r[1].Items);
    }
    [Fact] public void ContinuedBullet() => Assert.Equal(new[] { "First line wraps here and here.", "Second." }, Changelog.Parse("## 0.6.1\n- First line\n  wraps here\nand here.\n- Second.")[0].Items);
    [Fact] public void LooseTextDropped() => Assert.Equal("Item.", Assert.Single(Changelog.Parse("# Changelog\nLoose.\n- Ignored.\n## 0.6.1\nLoose.\n- Item.")[0].Items));
    [Theory][InlineData("")][InlineData("# Changelog\n- Item.")]
    public void NoHeading(string text) => Assert.Empty(Changelog.Parse(text));
    [Theory][InlineData("2026-10-30", "30 Oct 2026")][InlineData("2026-01-05", "5 Jan 2026")][InlineData("Oct 2026", "Oct 2026")][InlineData("30/10/2026", "30/10/2026")][InlineData("", "")]
    public void DateText(string written, string expected) => Assert.Equal(expected, Changelog.DateText(written));
    [Fact] public void ReleaseDate() { Assert.Null(new Release("0.6.1").DateText); Assert.Equal("30 Oct 2026", new Release("0.6.1", Date: "2026-10-30").DateText); }
}
public sealed class TranscriptTests
{
    [Theory][InlineData("hello world hello world hello world", "hello world")][InlineData("บน บน บน บน บน บน", "บน บน")][InlineData("การการการการการการการ", "การ")][InlineData("ใช่ ใช่ ใช่", "ใช่ ใช่ ใช่")]
    public void Collapse(string text, string expected) => Assert.Equal(expected, TranscriptCleaner.Collapse(text).Text);
    [Theory][InlineData(.49, 0)][InlineData(.5, 1)][InlineData(.85, 1)]
    public void FillerProbability(double p, int count) => Assert.Equal(count, TranscriptCleaner.Clean([new(0, 1, "ขอบคุณค่ะ", P: p)]).Lines.Count);
    [Fact] public void RunsAndFragments()
    {
        var r = TranscriptCleaner.Clean([new(0, 1, "the delivery is ready"), new(2, 3, "the delivery is ready"), new(4, 5, "the delivery is ready"), new(6, 7, "delivery is ready")]);
        Assert.Single(r.Lines); Assert.Equal(1, r.Runs); Assert.Equal(1, r.Fragments);
    }
    [Fact] public void LongRepeatAnywhere()
    {
        var r = TranscriptCleaner.Clean([new(0, 1, "the delivery is ready"), new(100, 101, "other thought"), new(400, 401, "the delivery is ready"), new(700, 701, "the delivery is ready")]);
        Assert.Equal(2, r.Lines.Count); Assert.Equal(2, r.Repeats);
    }
    [Fact] public void ShortBackchannelsStay() => Assert.Equal(3, TranscriptCleaner.Clean([new(0, 1, "ใช่"), new(2, 3, "ใช่"), new(4, 5, "ใช่")]).Lines.Count);
    [Fact] public void RerunsRepairedStretchOnce()
    {
        var calls = 0;
        var result = TranscriptCleaner.Clean([new(10, 11, "a long sentence"), new(12, 13, "a long sentence"), new(14, 15, "a long sentence")], (from, to) => { calls++; Assert.Equal(5, from); Assert.Equal(20, to); return [new(10, 15, "จริง ๆ พูดอีกอย่าง")]; });
        Assert.Equal(1, calls); Assert.Single(result.Retried); Assert.Equal("จริง ๆ พูดอีกอย่าง", Assert.Single(result.Lines).Text);
    }
    [Fact] public void DedupeOneToOneAndTimeBounded()
    {
        TranscriptLine[] others = [new(10, 12, "we will ship the release on Friday")];
        var r = TranscriptCleaner.Dedupe([new(11, 12, "we will ship the release on Friday"), new(90, 91, "we will ship the release on Friday"), new(11, 12, "okay"), new(11, 12, "I disagree and will explain the risk")], others);
        Assert.Equal(1, r.Dropped); Assert.Equal(3, r.Kept.Count);
    }
    [Fact] public void LeakOnlyRetriedAndOverlapping()
    {
        var r = TranscriptCleaner.DropLeak([new(1, 2, "a"), new(10, 11, "b"), new(20, 21, "c")], [new(10, 11, "different words")], [(9, 25)]);
        Assert.Equal(1, r.Dropped); Assert.Equal(2, r.Kept.Count);
    }
    [Fact] public void DiarizerParseAndAbsorb()
    {
        var segments = Diarizer.Parse("configuration\n0.0 -- 50.0 speaker_00\n50.0 -- 100.0 speaker_01\n49.0 -- 49.5 speaker_02\n4.0 -- 3.0 speaker_99");
        Assert.Equal(3, segments.Count); Assert.Equal(2, Diarizer.Absorb(segments).Select(s => s.Speaker).Distinct().Count()); Assert.Equal(0, Diarizer.SpeakerAt(25, segments)); Assert.Null(Diarizer.SpeakerAt(200, segments));
    }
    [Fact] public void LabelsFirstAppearanceAcrossTracks()
    {
        Assert.Equal(new[] { "Speaker 1", "Speaker 2", "Speaker 3", "Speaker 4", "Speaker 1" }, Transcripts.Labels([(1, 7), (0, 5), (1, 9), (0, 6), (1, 7)], ["Me", "Others"]));
        Assert.Equal(new[] { "Me", "Others" }, Transcripts.Labels([(0, 5), (1, 3)], ["Me", "Others"]));
    }
    [Fact] public void ThaiTokensSplitMidUtf8AreJoined()
    {
        var thai = Encoding.UTF8.GetBytes("ครับ");
        var parts = thai.Select((b, i) => new { offsets = new { from = i * 30, to = (i + 1) * 30 }, tokens = new[] { new { text = ((char)b).ToString(), p = .9 } } });
        var latin = JsonSerializer.Serialize(new { transcription = parts }, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        // Build raw JSON with byte-valued Latin-1 token strings, exactly as whisper writes them.
        var bytes = Encoding.Latin1.GetBytes(latin);
        var parsed = Transcripts.ParseWhisper(bytes); Assert.Equal("ครับ", Assert.Single(parsed).Text); Assert.Equal(.9, parsed[0].P!.Value, 8);
    }
    [Fact] public void WhisperSpecialTokensAndSentenceBreaks()
    {
        var raw = "{\"transcription\":[{\"offsets\":{\"from\":0,\"to\":500},\"tokens\":[{\"text\":\" Hello.\",\"p\":0.8},{\"text\":\"[_TT_0]\"}]},{\"offsets\":{\"from\":600,\"to\":1000},\"tokens\":[{\"text\":\" World\",\"p\":0.6}]}]}";
        Assert.Equal(new[] { "Hello.", "World" }, Transcripts.ParseWhisper(Encoding.UTF8.GetBytes(raw)).Select(l => l.Text));
    }
    [Fact] public void RenderConsecutiveSpeakersAndParse()
    {
        var text = Transcripts.Render([new(1, "Me", "Hello"), new(2, "Me", "again"), new(3, "Others", "Hi")], "Synthetic", DateTimeOffset.Parse("2026-10-30T10:00:00Z"), 90);
        Assert.Contains("· 2 min", text); var turns = Transcripts.Parse(text); Assert.Equal(2, turns.Count); Assert.Equal("Hello again", turns[0].Text); Assert.Equal(3, turns[1].Start);
    }
}
public sealed class StorageTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "minutes-test-" + Guid.NewGuid());
    public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
    [Theory][InlineData(null,"screen")][InlineData("call","screen")][InlineData("inPerson","voice")][InlineData("voice","voice")]
    public void LegacyModes(string? raw,string mode) => Assert.Equal(mode,Modes.Read(raw));
    [Fact] public void UnknownModeRejected() => Assert.Throws<JsonException>(() => Modes.Read("unknown"));
    [Fact] public void MetaRoundtripPreservesUnknownAndDates()
    {
        var meta = JsonSerializer.Deserialize<MeetingMeta>("{\"id\":\"test\",\"title\":\"Synthetic\",\"startedAt\":\"2026-10-30T10:00:00Z\",\"bundleID\":\"zoom\",\"groupID\":\"group\",\"futureField\":42,\"drive\":{\"files\":{}}}", JsonFiles.Options)!;
        Workspace.WriteMeta(root,meta); var read = Workspace.ReadMeta(root)!; Assert.Equal(meta.StartedAt,read.StartedAt); Assert.Equal("zoom",read.BundleID); Assert.Equal("group",read.GroupID); Assert.Equal(42,read.Extra!["futureField"].GetInt32()); Assert.NotNull(read.Drive);
    }
    [Fact] public void RenameRespectsUserEditedHeaderAndNoteIdentity()
    {
        var workspace = new Workspace(root); var note = workspace.MakeNote();
        JsonFiles.AtomicWrite(Path.Combine(note.Folder,"transcript.md"),"# Untitled\r\n\nbody"); JsonFiles.AtomicWrite(Path.Combine(note.Folder,"summary.md"),"# Hand edited\nbody");
        var renamed = workspace.Rename(note,"Planning"); Assert.Equal(note.Meta.Id,renamed.Meta.Id); Assert.True(renamed.Meta.IsNote); Assert.Equal("# Planning\r\n\nbody",File.ReadAllText(Path.Combine(renamed.Folder,"transcript.md"))); Assert.StartsWith("# Hand edited",File.ReadAllText(Path.Combine(renamed.Folder,"summary.md")));
    }
    [Fact] public void SyncPrivacyAndMediaPolicy()
    {
        var note = new Workspace(root).MakeNote(); foreach(var n in new[]{"me.wav","others.flac","meta.json.backup","briefing.m4a","summary.md"}) JsonFiles.AtomicWrite(Path.Combine(note.Folder,n),"synthetic");
        var names=SyncPlan.Files(note.Folder,note.Meta); Assert.Contains("me.wav",names); Assert.DoesNotContain("briefing.m4a",names); Assert.DoesNotContain("meta.json",names);
        note.Meta.VideoDeletedAt=DateTimeOffset.Now; Assert.DoesNotContain("me.wav",SyncPlan.Files(note.Folder,note.Meta)); note.Meta.Confidential=true; Assert.Empty(SyncPlan.Files(note.Folder,note.Meta));
    }
    [Theory][InlineData("../other")][InlineData("/absolute")][InlineData("frames/../../secret")][InlineData("C:\\outside")]
    public void RelativePathsStayInside(string path) => Assert.Throws<IOException>(() => SyncPlan.SafePath(root,path));
    [Fact] public async Task FolderSyncCopiesAndWithdrawsConfidential()
    {
        var workspace=new Workspace(Path.Combine(root,"workspace"));var meeting=workspace.MakeNote();var destination=Path.Combine(root,"cloud");Directory.CreateDirectory(destination);
        var sync=new FolderSync(workspace);await sync.CopyAsync(meeting,destination);
        var copy=Path.Combine(destination,"Minutes",Path.GetFileName(meeting.Folder));Assert.True(File.Exists(Path.Combine(copy,"notes.md")));Assert.False(File.Exists(Path.Combine(copy,"meta.json")));
        workspace.Update(meeting.Folder,m=>m.Confidential=true);await sync.CopyAsync(meeting,destination);Assert.False(Directory.Exists(copy));Assert.Null(Workspace.ReadMeta(meeting.Folder)!.Sync);
    }
    [Fact] public void RevisionRejectsDuplicateTitleAndTurnEdits()
    {
        var docs=new Dictionary<string,string>{{"summary.md","# Title\n\nword word"},{"transcript.md","# Title\n\n**[00:00:01] Me:** word\n"}};
        Assert.Throws<InvalidDataException>(()=>CommentRevision.Apply([new(null,"word","changed")],docs,"summary.md"));
        Assert.Throws<InvalidDataException>(()=>CommentRevision.Apply([new(null,"# Title","# Changed")],docs,"summary.md"));
        Assert.Throws<InvalidDataException>(()=>CommentRevision.Apply([new(null,"00:00:01","00:00:02")],docs,"transcript.md"));
        var changed=CommentRevision.Apply([new(null,"word","clear")],docs,"transcript.md");Assert.Contains("clear",changed["transcript.md"]);
    }
    [Fact] public void RevisionUndoAllowsRenameButRefusesConcurrentChanges()
    {
        var before=new Dictionary<string,string>{{"summary.md","# Title\n\nold"}};var after=new Dictionary<string,string>{{"summary.md","# Title\n\nnew"}};var reply=new CommentMessage();
        CommentRevision.Save(root,reply,before,after);JsonFiles.AtomicWrite(Path.Combine(root,"summary.md"),"# Renamed\n\nnew");CommentRevision.Undo(root,reply);Assert.Equal("# Renamed\n\nold",File.ReadAllText(Path.Combine(root,"summary.md")));
        var second=new CommentMessage();CommentRevision.Save(root,second,before,after);JsonFiles.AtomicWrite(Path.Combine(root,"summary.md"),"# Title\n\nmanual");Assert.Throws<InvalidOperationException>(()=>CommentRevision.Undo(root,second));
    }
    [Fact] public void AnchoringUsesTimeForRepeatedQuote()
    {
        var doc=new CommentDocument(["same quote","same quote"],[1,10]);var anchor=doc.Anchor(new(){Quote="same quote",LineTime=10});Assert.Equal(1,anchor!.Unit);
    }
    [Fact] public void AnchoringFallsBackToContext()
    {
        var doc=new CommentDocument(["a long prefix changed words long suffix here"]);var anchor=doc.Anchor(new(){Quote="old words",Prefix="a long prefix ",Suffix=" long suffix here"});Assert.NotNull(anchor);Assert.Equal("changed words",doc.Units[0]!.Substring(anchor.Start,anchor.Length));
    }
}
public sealed class PromptTests
{
    [Theory][InlineData("thai","## สรุป")][InlineData("english","## Summary")][InlineData("meeting","Second copy")]
    public void LanguageAndSections(string language,string expected) { var p=SummaryPrompts.Prompt(language);Assert.Contains(expected,p);Assert.DoesNotContain("\\(w.",p);Assert.Contains("Never guess an owner",p); }
    [Fact] public void OptionalPromptRules() { var p=SummaryPrompts.Prompt(voice:true,events:true,pictures:true);Assert.Contains("Event: <number>",p);Assert.Contains("Voice mode",p);Assert.Contains("up to 6",p); }
    [Fact] public void ChosenEventStripsInvalidOrCurrent()
    { Assert.Equal((1,"\nbody"),SummaryPrompts.ChosenEvent(" Event: 2\nbody",3));Assert.Null(SummaryPrompts.ChosenEvent("Event: 1\nbody",3).Index);Assert.Equal("\nbody",SummaryPrompts.ChosenEvent("Event: 99\nbody",3).Text);Assert.Equal("body",SummaryPrompts.ChosenEvent("body",3).Text); }
    [Fact] public void EventCannotRenameNoteOrHandPicked()
    {
        var now=DateTimeOffset.Now;CalendarEvent[] events=[new("One",now,now.AddHours(1)),new("Two",now,now.AddHours(1))];var m=new MeetingMeta{Title="Two"};Assert.Equal("Two",SummaryPrompts.ChoosableEvents(m,events)[0].Title);m.EventPicked=true;Assert.Empty(SummaryPrompts.ChoosableEvents(m,events));m.EventPicked=null;m.Note=true;Assert.Empty(SummaryPrompts.ChoosableEvents(m,events));
    }
    [Fact] public void UnknownRepeatedAndExcessPicturesRemoved() => Assert.Equal("![](frames/a.jpg)",SummaryPrompts.KeepKnownPictures("![](frames/a.jpg)\n![](frames/a.jpg)\n![](frames/b.jpg)\n![](frames/unknown.jpg)",new HashSet<string>{"frames/a.jpg","frames/b.jpg"},1));
    [Fact] public void VoiceCalendarRanksRoomBeforeCall()
    {
        var now=DateTimeOffset.Now;var call=new CalendarEvent("Call",now,now.AddHours(1),"https://teams.microsoft.com/meet");var room=new CalendarEvent("Room",now.AddMinutes(1),now.AddHours(1));Assert.Equal(room,CalendarRanking.Ranked([call,room],now,null,true)[0]);Assert.Equal(call,CalendarRanking.Ranked([room,call],now,"ms-teams")[0]);
    }
}
