namespace Minutes.Core;

public record MicUser(string AppName,string Owner,uint ProcessId);
public record RecordedCall(string? App,bool AutoStop);
public record DetectorAction(string Kind,string? App=null,string? Owner=null,double? Remaining=null);
public sealed class MeetingDetector
{
    public int PollsBeforePrompt { get; set; }=2;
    public double AutoStopAfter { get; set; }=30;
    public double AskStopAfter { get; set; }=3;
    public double DeclineFor { get; set; }=15*60;
    public double CalendarEvery { get; set; }=30;
    public bool KeepRecording { get; set; }
    public Dictionary<string,DateTimeOffset> Declined { get; }=[];
    public Dictionary<string,DateTimeOffset> AskOnly { get; }=[];
    private Dictionary<string,string> bundles=[];
    private Dictionary<string,int> micPolls=[];
    private DateTimeOffset? micFreeSince,outputFreeSince,calendarReadAt;
    private bool outputSeen;
    public IReadOnlyList<DetectorAction> Poll(IReadOnlyList<MicUser> candidates,DateTimeOffset now,RecordedCall? recording,string? prompted,bool stopPromptShown,Func<string,bool> isAllowed,Func<string,bool> alwaysRecord,Func<string?,DateTimeOffset,bool>? meetingStarted=null,ISet<string>? outputApps=null)
    {
        meetingStarted??=(_,_)=>false;outputApps??=new HashSet<string>();var apps=candidates.Select(c=>c.AppName).ToHashSet(StringComparer.Ordinal);
        bundles=candidates.GroupBy(c=>c.AppName).ToDictionary(g=>g.Key,g=>g.First().Owner);
        foreach(var app in Declined.Keys.Where(a=>!apps.Contains(a)||(now-Declined[a]).TotalSeconds>=DeclineFor).ToArray())Declined.Remove(app);
        foreach(var app in AskOnly.Keys.Where(a=>!apps.Contains(a)).ToArray())AskOnly.Remove(app);
        if((Declined.Count>0||AskOnly.Count>0)&&(calendarReadAt==null||(now-calendarReadAt.Value).TotalSeconds>=CalendarEvery))
        {
            calendarReadAt=now;
            foreach(var app in Declined.Keys.Concat(AskOnly.Keys).Distinct().ToArray())
            {
                if(Declined.TryGetValue(app,out var since)&&meetingStarted(bundles.GetValueOrDefault(app),since))Declined.Remove(app);
                if(AskOnly.TryGetValue(app,out since)&&meetingStarted(bundles.GetValueOrDefault(app),since))AskOnly.Remove(app);
            }
        }
        micPolls=apps.ToDictionary(a=>a,a=>micPolls.GetValueOrDefault(a)+1);
        if(recording!=null)
        {
            if(!recording.AutoStop)return [];
            var playing=recording.App!=null&&outputApps.Contains(recording.App);if(playing){outputSeen=true;outputFreeSince=null;}
            var callHasMic=recording.App!=null?apps.Contains(recording.App):apps.Count>0;
            if(callHasMic)
            {
                var back=stopPromptShown&&!KeepRecording;micFreeSince=outputFreeSince=null;KeepRecording=false;
                if(!stopPromptShown)return [];
                return back&&recording.App!=null?[new("closeStopPrompt"),new("askSameCall",recording.App)]:[new("closeStopPrompt")];
            }
            if(KeepRecording)
            {
                if(!outputSeen||playing)return [];
                if(outputFreeSince==null){outputFreeSince=now;return [];}
                return(now-outputFreeSince.Value).TotalSeconds>=AutoStopAfter?[new("stop")]:[];
            }
            if(micFreeSince==null){micFreeSince=now;return [];}
            var free=(now-micFreeSince.Value).TotalSeconds;
            if(free>=AutoStopAfter)return[new("stop")];
            return!stopPromptShown&&free>=AskStopAfter?[new("askToStop",Remaining:AutoStopAfter-free)]:[];
        }
        var actions=new List<DetectorAction>();
        if(prompted!=null&&!apps.Contains(prompted)){actions.Add(new("closePrompt"));prompted=null;}
        var ask=candidates.Where(c=>isAllowed(c.Owner)).Select(c=>c.AppName).Distinct().Order(StringComparer.Ordinal).FirstOrDefault(a=>micPolls.GetValueOrDefault(a)>=PollsBeforePrompt&&!Declined.ContainsKey(a));
        if(prompted!=null||ask==null)return actions;
        var bundle=bundles.GetValueOrDefault(ask);actions.Add(new(bundle!=null&&!AskOnly.ContainsKey(ask)&&alwaysRecord(bundle)?"recordWithoutAsking":"ask",ask,bundle));return actions;
    }
    public void Decline(string app,DateTimeOffset now){Declined[app]=now;AskOnly[app]=now;}
    public void StoppedByHand(string? app,DateTimeOffset now){if(app==null)return;Declined.Remove(app);AskOnly[app]=now;}
    public void RecordingStarted(){micFreeSince=outputFreeSince=null;KeepRecording=outputSeen=false;}
}
public static class MeetingApps
{
    public static readonly IReadOnlyDictionary<string,string> Known=new Dictionary<string,string>(StringComparer.OrdinalIgnoreCase)
    {
        ["ms-teams"]="Microsoft Teams",["Teams"]="Microsoft Teams (classic)",["Zoom"]="Zoom",["Webex"]="Webex Meetings",["CiscoCollabHost"]="Webex",["slack"]="Slack",["Discord"]="Discord",["LINE"]="LINE",["chrome"]="Google Chrome",["msedge"]="Microsoft Edge",["firefox"]="Firefox",["brave"]="Brave",["Arc"]="Arc"
    };
    public static bool Allowed(string process,bool any,ISet<string> off,ISet<string> on)=>any||on.Contains(process)||!off.Contains(process)&&Known.ContainsKey(process);
}
