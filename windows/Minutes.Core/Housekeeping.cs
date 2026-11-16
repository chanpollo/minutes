namespace Minutes.Core;

public record RetentionPolicy(int KeepVideoDays = 90, int KeepAudioDays = 0);
public record RetentionPlan(IReadOnlyList<string> Videos, IReadOnlyList<string> Tracks);
public static class Housekeeping
{
    public static RetentionPlan Plan(string folder, MeetingMeta meta, DateTimeOffset now, RetentionPolicy policy, bool held = false)
    {
        if (held || meta.IsNote) return new([], []);
        var age = (now - (meta.EndedAt ?? meta.StartedAt)).TotalDays;
        bool Exists(string name) => File.Exists(Path.Combine(folder, name));
        var video = policy.KeepVideoDays > 0 && age > policy.KeepVideoDays ? new[] { "meeting.mp4", "screen.mov" }.Where(Exists).ToArray() : [];
        var audio = policy.KeepAudioDays > 0 && age > policy.KeepAudioDays && Exists("transcript.md") ? new[] { "me.wav", "others.wav", "me.flac", "others.flac" }.Where(Exists).ToArray() : [];
        return new(video, audio);
    }
    public static long Run(Workspace workspace, DateTimeOffset now, RetentionPolicy policy, ISet<string>? held = null)
    {
        long freed = 0;
        foreach (var meeting in workspace.Meetings())
        {
            var plan = Plan(meeting.Folder, meeting.Meta, now, policy, held?.Contains(meeting.Meta.Id) == true);
            foreach (var name in plan.Videos.Concat(plan.Tracks))
            {
                var path = Path.Combine(meeting.Folder, name); var size = new FileInfo(path).Length; File.Delete(path); freed += size;
            }
            if (plan.Videos.Count > 0 || plan.Tracks.Count > 0) workspace.Update(meeting.Folder, m => { if (plan.Videos.Count > 0) m.VideoDeletedAt = now; if (plan.Tracks.Count > 0) m.AudioDeletedAt = now; });
        }
        return freed;
    }
}
