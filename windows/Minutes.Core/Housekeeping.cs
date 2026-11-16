namespace Minutes.Core;

public record RetentionPolicy(int KeepVideoDays = 90, int KeepAudioDays = 0);
public record RetentionPlan(IReadOnlyList<string> Videos, IReadOnlyList<string> Tracks);
public static class Housekeeping
{
    public static RetentionPlan Plan(string folder, MeetingMeta meta, DateTimeOffset now, RetentionPolicy policy, bool held = false)
    {
        if (held || Workspace.IsNote(folder,meta)) return new([], []);
        var age = (now - (meta.EndedAt ?? meta.StartedAt)).TotalDays;
        bool Exists(string name) => File.Exists(Path.Combine(folder, name));
        var video = policy.KeepVideoDays > 0 && age > policy.KeepVideoDays ? new[] { "meeting.mp4", "screen.mov", "screen.mp4", "meeting.partial.mp4" }.Where(Exists).ToArray() : [];
        var audio = policy.KeepAudioDays > 0 && age > policy.KeepAudioDays && Exists("transcript.md") ? new[] { "me.wav", "others.wav", "me.flac", "others.flac" }.Where(Exists).ToArray() : [];
        return new(video, audio);
    }
    public static long Run(Workspace workspace, DateTimeOffset now, RetentionPolicy policy, ISet<string>? held = null,Action<string>? delete=null)
    {
        delete??=File.Delete;long freed = 0;
        foreach (var meeting in workspace.Meetings())
        {
            var plan = Plan(meeting.Folder, meeting.Meta, now, policy, held?.Contains(meeting.Meta.Id) == true);
            var removedVideos=0;var removedTracks=0;
            foreach(var name in plan.Videos.Concat(plan.Tracks))
            {
                try
                {
                    var path=Path.Combine(meeting.Folder,name);var size=new FileInfo(path).Length;delete(path);freed+=size;
                    if(plan.Videos.Contains(name))removedVideos++;else removedTracks++;
                }
                catch(Exception error)when(error is IOException or UnauthorizedAccessException){}
            }
            if(removedVideos>0||removedTracks>0)workspace.Update(meeting.Folder,m=>{if(removedVideos>0)m.VideoDeletedAt=now;if(removedTracks>0)m.AudioDeletedAt=now;});
        }
        return freed;
    }
}
